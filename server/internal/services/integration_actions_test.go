package services

import (
	"context"
	"errors"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/community"
	"shenliyuan/internal/models"
	"sync"
	"testing"
	"time"
)

func integrationActionFixture(t *testing.T) (*gorm.DB, *IntegrationActionService, models.IntegrationBinding, models.Post) {
	db := integrationTestDB(t)
	require.NoError(t, db.AutoMigrate(&models.Post{}, &models.Reply{}, &models.WaterSection{}, &models.WaterSectionMute{}, &models.Notification{}))
	integrationTestUser(t, db, 1)
	require.NoError(t, db.Create(&models.UserLegalConsent{UserID: 1, Document: models.LegalDocumentCommunityRules, AcknowledgementType: "rules_acceptance", Version: models.LegalDocumentVersion, AcceptedAt: time.Now()}).Error)
	auth := NewIntegrationAuthService(db)
	binding, _ := integrationAuthorize(t, auth, 1, uuid.NewString())
	require.NoError(t, db.Create(&models.WaterSection{Slug: "campus_life", Title: "校园生活", Status: "active"}).Error)
	post := models.Post{AuthorID: 1, BoardID: models.BoardShuitie, PostType: "campus_life", ContentKind: models.PostContentKindNormal, Status: models.PostStatusNormal, Content: "合成帖子", CreatedAt: time.Now().Add(-time.Hour)}
	require.NoError(t, db.Create(&post).Error)
	return db, &IntegrationActionService{Auth: auth, ValidSticker: func(v string) bool { return v == "test_sticker" }}, binding, post
}
func integrationReplyProposal(post models.Post) IntegrationProposal {
	return IntegrationProposal{OperationID: uuid.NewString(), Kind: "reply", PostID: post.ID, SourceVersion: community.PostDTO(post, 10000).SourceVersion, Content: "合成评论"}
}
func integrationDecision(t *testing.T, s *IntegrationActionService, a models.IntegrationAction) IntegrationActionDecision {
	t.Helper()
	p, err := s.Preview(context.Background(), 1, a.ID, nil)
	require.NoError(t, err)
	return IntegrationActionDecision{Allow: true, Nonce: p.Nonce, Version: a.Version, PayloadHash: a.PayloadHash}
}
func TestIntegrationActionOwnerConfirmationAndIdempotency(t *testing.T) {
	db, s, b, post := integrationActionFixture(t)
	ctx := context.Background()
	p := integrationReplyProposal(post)
	action, err := s.Propose(ctx, b, p)
	require.NoError(t, err)
	same, err := s.Propose(ctx, b, p)
	require.NoError(t, err)
	require.Equal(t, action.ID, same.ID)
	p.Content = "不同内容"
	_, err = s.Propose(ctx, b, p)
	require.EqualError(t, err, "operation_conflict")
	_, err = s.Preview(ctx, 2, action.ID, nil)
	require.Error(t, err)
	other := b
	other.ID = uuid.NewString()
	_, err = s.Preview(ctx, 1, action.ID, &other)
	require.Error(t, err)
	plugin, err := s.Preview(ctx, 1, action.ID, &b)
	require.NoError(t, err)
	require.Empty(t, plugin.Nonce)
	var count int64
	require.NoError(t, db.Model(&models.Reply{}).Count(&count).Error)
	require.Zero(t, count)
	d := integrationDecision(t, s, action)
	wrong := d
	wrong.Nonce = "forged"
	_, err = s.Decide(ctx, 1, action.ID, wrong)
	require.EqualError(t, err, "confirmation_expired")
	wrong = d
	wrong.Version++
	_, err = s.Decide(ctx, 1, action.ID, wrong)
	require.EqualError(t, err, "draft_changed")
	var wg sync.WaitGroup
	errs := make(chan error, 6)
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, err := s.Decide(ctx, 1, action.ID, d); errs <- err }()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		require.NoError(t, err)
	}
	require.NoError(t, db.Model(&models.Reply{}).Count(&count).Error)
	require.EqualValues(t, 1, count)
	var reply models.Reply
	require.NoError(t, db.First(&reply).Error)
	require.Equal(t, "assistant", reply.ContentOrigin)
	require.Contains(t, reply.Content, "助手代发")
	require.NoError(t, db.First(&post, post.ID).Error)
	require.Equal(t, 1, post.ReplyCount)
	require.Zero(t, post.ViewCount)
}
func TestIntegrationDraftBlockingAndRollback(t *testing.T) {
	for _, reason := range []string{"revoked", "identity_changed", "hidden", "edited", "expired", "nonce_expired", "muted", "rules", "binding_scope", "audit_failure"} {
		t.Run(reason, func(t *testing.T) {
			db, s, b, post := integrationActionFixture(t)
			ctx := context.Background()
			action, err := s.Propose(ctx, b, integrationReplyProposal(post))
			require.NoError(t, err)
			d := integrationDecision(t, s, action)
			switch reason {
			case "revoked":
				require.NoError(t, s.Auth.Revoke(ctx, 1, b.ID))
			case "identity_changed":
				require.NoError(t, db.Model(&models.AcademicIdentityBinding{}).Where("user_id = 1").Update("binding_version", 2).Error)
			case "hidden":
				require.NoError(t, db.Model(&post).Update("status", models.PostStatusModeratedHidden).Error)
			case "edited":
				require.NoError(t, db.Model(&post).Update("content", "变更后内容").Error)
			case "expired":
				require.NoError(t, db.Model(&action).Update("expires_at", time.Now().Add(-time.Second)).Error)
			case "nonce_expired":
				require.NoError(t, db.Model(&action).Update("confirm_expires_at", time.Now().Add(-time.Second)).Error)
			case "muted":
				require.NoError(t, db.Create(&models.WaterSectionMute{SectionID: 1, UserID: 1, Status: models.MuteStatusActive}).Error)
			case "rules":
				require.NoError(t, db.Where("user_id = 1 AND document = ?", models.LegalDocumentCommunityRules).Delete(&models.UserLegalConsent{}).Error)
			case "binding_scope":
				require.NoError(t, db.Model(&b).Update("scopes", IntegrationReadScope).Error)
			case "audit_failure":
				require.NoError(t, db.Callback().Create().Before("gorm:create").Register("integration_fail_audit", func(tx *gorm.DB) {
					if tx.Statement.Table == "integration_audits" {
						tx.AddError(errors.New("injected audit failure"))
					}
				}))
			}
			_, err = s.Decide(ctx, 1, action.ID, d)
			require.Error(t, err)
			var count int64
			require.NoError(t, db.Model(&models.Reply{}).Count(&count).Error)
			require.Zero(t, count)
			require.NoError(t, db.First(&post, post.ID).Error)
			require.Zero(t, post.ReplyCount)
		})
	}
}
func TestIntegrationSourceStatisticsDoNotInvalidateAndThreadIsDerived(t *testing.T) {
	db, s, b, post := integrationActionFixture(t)
	ctx := context.Background()
	root := models.Reply{PostID: post.ID, AuthorID: 1, Content: "根评论", Status: models.ReplyStatusNormal}
	require.NoError(t, db.Create(&root).Error)
	target := models.Reply{PostID: post.ID, AuthorID: 1, ParentReplyID: &root.ID, Content: "子评论", Status: models.ReplyStatusNormal}
	require.NoError(t, db.Create(&target).Error)
	p := integrationReplyProposal(post)
	p.ReplyToReplyID = target.ID
	p.ReplySourceVersion = community.ReplyDTO(target).SourceVersion
	p.StickerID = "test_sticker"
	p.Content = ""
	action, err := s.Propose(ctx, b, p)
	require.NoError(t, err)
	require.NoError(t, db.Model(&post).Updates(map[string]interface{}{"like_count": 10, "view_count": 50}).Error)
	d := integrationDecision(t, s, action)
	a, err := s.Decide(ctx, 1, action.ID, d)
	require.NoError(t, err)
	var reply models.Reply
	require.NoError(t, db.First(&reply, *a.ReplyID).Error)
	require.Equal(t, &root.ID, reply.ParentReplyID)
	require.Equal(t, &target.ID, reply.ReplyToReplyID)
	require.Equal(t, &target.AuthorID, reply.ReplyToUserID)
	require.Equal(t, &p.StickerID, reply.StickerID)
}
func TestIntegrationCreatesActualPostAndRejectsUnexpectedTargets(t *testing.T) {
	db, s, b, post := integrationActionFixture(t)
	ctx := context.Background()
	p := IntegrationProposal{OperationID: uuid.NewString(), Kind: "post", PostType: "campus_life", Title: "合成标题", Content: "合成正文"}
	action, err := s.Propose(ctx, b, p)
	require.NoError(t, err)
	d := integrationDecision(t, s, action)
	a, err := s.Decide(ctx, 1, action.ID, d)
	require.NoError(t, err)
	var created models.Post
	require.NoError(t, db.First(&created, *a.PostID).Error)
	require.EqualValues(t, 1, created.AuthorID)
	require.Equal(t, "assistant", created.ContentOrigin)
	p = integrationReplyProposal(post)
	p.ReplyToReplyID = 999
	p.ReplySourceVersion = p.SourceVersion
	_, err = s.Propose(ctx, b, p)
	require.Error(t, err)
	p = integrationReplyProposal(post)
	p.StickerID = "arbitrary"
	_, err = s.Propose(ctx, b, p)
	require.EqualError(t, err, "invalid_sticker")
}

func TestIntegrationConcurrentPublishAndRevokeSerializeOnUser(t *testing.T) {
	db, s, b, post := integrationActionFixture(t)
	if db.Dialector.Name() != "postgres" {
		t.Skip("需要显式隔离 PostgreSQL 才能验证真实行锁")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	a, err := s.Propose(ctx, b, integrationReplyProposal(post))
	require.NoError(t, err)
	d := integrationDecision(t, s, a)
	entered, release := make(chan struct{}), make(chan struct{})
	require.NoError(t, db.Callback().Create().Before("gorm:create").Register("integration_publish_barrier", func(tx *gorm.DB) {
		if tx.Statement.Table == "replies" {
			close(entered)
			select {
			case <-release:
			case <-ctx.Done():
				tx.AddError(ctx.Err())
			}
		}
	}))
	published, revoked := make(chan error, 1), make(chan error, 1)
	go func() { _, err := s.Decide(ctx, 1, a.ID, d); published <- err }()
	select {
	case <-entered:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	go func() { revoked <- s.Auth.Revoke(ctx, 1, b.ID) }()
	close(release)
	require.NoError(t, <-published)
	require.NoError(t, <-revoked)
	require.Error(t, s.Auth.CheckBinding(ctx, b))
	var n int64
	require.NoError(t, db.Model(&models.Reply{}).Count(&n).Error)
	require.EqualValues(t, 1, n)
}

func TestIntegrationDatabaseRateLimitAndRetention(t *testing.T) {
	db, s, b, post := integrationActionFixture(t)
	ctx := context.Background()
	var wg sync.WaitGroup
	accepted := make(chan bool, 40)
	for i := 0; i < 40; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			accepted <- s.Auth.AllowRequest(ctx, "fixed-test", "synthetic", 7, time.Hour) == nil
		}()
	}
	wg.Wait()
	close(accepted)
	n := 0
	for ok := range accepted {
		if ok {
			n++
		}
	}
	require.Equal(t, 7, n)
	a, err := s.Propose(ctx, b, integrationReplyProposal(post))
	require.NoError(t, err)
	require.NoError(t, db.Model(&a).Update("expires_at", time.Now().Add(-time.Hour)).Error)
	require.NoError(t, s.Auth.Purge(ctx))
	require.NoError(t, db.First(&a, "id = ?", a.ID).Error)
	require.Equal(t, "expired", a.State)
	require.JSONEq(t, `{}`, string(a.Payload))
}
