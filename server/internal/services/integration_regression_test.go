package services

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/community"
	"shenliyuan/internal/models"
)

func TestIntegrationRefreshReuseAfterOriginalExpiryRevokesSuccessor(t *testing.T) {
	db := integrationTestDB(t)
	integrationTestUser(t, db, 1)
	auth := NewIntegrationAuthService(db)
	now := time.Now()
	auth.Now = func() time.Time { return now }
	binding, device := integrationAuthorize(t, auth, 1, uuid.NewString())
	now = now.Add(6 * time.Second)
	original, err := auth.ExchangeDevice(context.Background(), device.DeviceCode)
	require.NoError(t, err)
	now = now.Add(6 * 24 * time.Hour)
	successor, err := auth.Refresh(context.Background(), original.RefreshToken)
	require.NoError(t, err)
	now = now.Add(2 * 24 * time.Hour)
	_, err = auth.Refresh(context.Background(), original.RefreshToken)
	require.EqualError(t, err, "invalid_grant")
	require.Error(t, auth.CheckBinding(context.Background(), binding), "过期的已使用旧凭证重放也应撤销同一授权")
	_, err = auth.Refresh(context.Background(), successor.RefreshToken)
	require.EqualError(t, err, "invalid_grant")
}

func TestIntegrationExpiredRefreshDoesNotRevokeUnusedOrReplacement(t *testing.T) {
	for _, scenario := range []string{"unused", "replaced"} {
		t.Run(scenario, func(t *testing.T) {
			db := integrationTestDB(t)
			integrationTestUser(t, db, 1)
			auth := NewIntegrationAuthService(db)
			now := time.Now()
			auth.Now = func() time.Time { return now }
			b, device := integrationAuthorize(t, auth, 1, uuid.NewString())
			now = now.Add(6 * time.Second)
			original, err := auth.ExchangeDevice(context.Background(), device.DeviceCode)
			require.NoError(t, err)
			var replacement models.IntegrationBinding
			var replacementTokens IntegrationTokenResponse
			if scenario == "replaced" {
				now = now.Add(6 * 24 * time.Hour)
				_, err = auth.Refresh(context.Background(), original.RefreshToken)
				require.NoError(t, err)
				next, err := auth.RequestDevice(context.Background(), uuid.NewString(), "合成替换安装", "community:read")
				require.NoError(t, err)
				consent, err := auth.LookupConsent(context.Background(), 1, next.UserCode)
				require.NoError(t, err)
				replacement, err = auth.DecideConsent(context.Background(), 1, consent.ID, IntegrationConsentDecision{Allow: true, Scopes: consent.RequestedScopes, Nonce: consent.Nonce, ReplaceBindingID: b.ID, ExpectedEpoch: b.Epoch})
				require.NoError(t, err)
				now = now.Add(6 * time.Second)
				replacementTokens, err = auth.ExchangeDevice(context.Background(), next.DeviceCode)
				require.NoError(t, err)
				now = now.Add(2 * 24 * time.Hour)
			} else {
				now = now.Add(8 * 24 * time.Hour)
			}
			_, err = auth.Refresh(context.Background(), original.RefreshToken)
			require.EqualError(t, err, "invalid_grant")
			if scenario == "replaced" {
				require.NoError(t, auth.CheckBinding(context.Background(), replacement))
				_, err = auth.Refresh(context.Background(), replacementTokens.RefreshToken)
				require.NoError(t, err)
			} else {
				require.NoError(t, auth.CheckBinding(context.Background(), b))
			}
		})
	}
}

func TestIntegrationNotificationRecipientAndCommitDelivery(t *testing.T) {
	for _, kind := range []string{"post_author", "root_author", "child_author", "sticker", "self"} {
		t.Run(kind, func(t *testing.T) {
			db, s, b, post := integrationActionFixture(t)
			require.NoError(t, db.Create(&[]models.User{{ID: 2, Nickname: "合成作者", PasswordHash: "synthetic", AccountStatus: "active"}, {ID: 3, Nickname: "合成子回复作者", PasswordHash: "synthetic", AccountStatus: "active"}}).Error)
			if kind != "self" {
				require.NoError(t, db.Model(&post).Update("author_id", 2).Error)
			}
			p := integrationReplyProposal(post)
			recipient := uint(2)
			if kind == "self" {
				recipient = 1
			}
			if kind == "root_author" || kind == "child_author" {
				root := models.Reply{AuthorID: 2, PostID: post.ID, Content: "合成根评论", Status: models.ReplyStatusNormal}
				require.NoError(t, db.Create(&root).Error)
				target := root
				if kind == "child_author" {
					target = models.Reply{AuthorID: 3, PostID: post.ID, ParentReplyID: &root.ID, Content: "合成子评论", Status: models.ReplyStatusNormal}
					require.NoError(t, db.Create(&target).Error)
					recipient = 3
				}
				p.ReplyToReplyID = target.ID
				p.ReplySourceVersion = community.ReplyDTO(target).SourceVersion
			}
			if kind == "sticker" {
				p.Content = ""
				p.StickerID = "test_sticker"
			}
			action, err := s.Propose(context.Background(), b, p)
			require.NoError(t, err)
			decision := integrationDecision(t, s, action)
			deliveries := 0
			s.AfterReplyCommit = func(n models.Notification) {
				deliveries++
				require.Equal(t, recipient, n.UserID)
				ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				defer cancel()
				var stored models.IntegrationAction
				require.NoError(t, db.WithContext(ctx).First(&stored, "id = ?", action.ID).Error)
				require.Equal(t, "published", stored.State, "提交后才允许外部投递")
				require.Equal(t, *stored.ReplyID, n.RelatedID)
			}
			for i := 0; i < 2; i++ {
				_, err = s.Decide(context.Background(), 1, action.ID, decision)
				require.NoError(t, err)
			}
			var rows []models.Notification
			require.NoError(t, db.Find(&rows).Error)
			if kind == "self" {
				require.Empty(t, rows)
				require.Zero(t, deliveries)
			} else {
				require.Len(t, rows, 1)
				require.Equal(t, 1, deliveries)
				require.Equal(t, recipient, rows[0].UserID)
				require.Contains(t, rows[0].Content, "助手代发")
				require.NotEmpty(t, rows[0].DedupKey)
				require.NoError(t, db.Model(&rows[0]).Update("is_read", true).Error)
				replay, err := CreateReplyNotification(db, recipient, 1, rows[0].RelatedID, post.ID, rows[0].Content)
				require.NoError(t, err)
				require.Nil(t, replay)
				require.NoError(t, db.First(&rows[0], rows[0].ID).Error)
				require.True(t, rows[0].IsRead, "重复事件不能重新变为未读")
			}
		})
	}
}

func TestIntegrationNotificationAndDeliveryRollback(t *testing.T) {
	for _, fail := range []string{"notifications", "integration_audits", "rejected"} {
		t.Run(fail, func(t *testing.T) {
			db, s, b, post := integrationActionFixture(t)
			require.NoError(t, db.Create(&models.User{ID: 2, Nickname: "合成收件人", PasswordHash: "synthetic", AccountStatus: "active"}).Error)
			require.NoError(t, db.Model(&post).Update("author_id", 2).Error)
			a, err := s.Propose(context.Background(), b, integrationReplyProposal(post))
			require.NoError(t, err)
			decision := integrationDecision(t, s, a)
			deliveries := 0
			s.AfterReplyCommit = func(models.Notification) { deliveries++ }
			require.NoError(t, db.Callback().Create().Before("gorm:create").Register("fail_notification_commit", func(tx *gorm.DB) {
				if tx.Statement.Table == fail {
					tx.AddError(errors.New("synthetic delivery failure"))
				}
			}))
			if fail == "rejected" {
				decision.Allow = false
			}
			_, err = s.Decide(context.Background(), 1, a.ID, decision)
			if fail == "rejected" {
				require.NoError(t, err)
			} else {
				require.Error(t, err)
			}
			var notifications, replies int64
			require.NoError(t, db.Model(&models.Notification{}).Count(&notifications).Error)
			require.NoError(t, db.Model(&models.Reply{}).Count(&replies).Error)
			require.Zero(t, notifications)
			require.Zero(t, replies)
			require.Zero(t, deliveries)
			require.NoError(t, db.First(&post, post.ID).Error)
			require.Zero(t, post.ReplyCount)
			require.NoError(t, db.First(&a, "id = ?", a.ID).Error)
			if fail == "rejected" {
				require.Equal(t, "rejected", a.State)
			} else {
				require.Equal(t, "pending", a.State)
			}
		})
	}
}

func TestIntegrationReplyCreatesOneRecipientNotification(t *testing.T) {
	db, s, b, post := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.Notification{}))
	require.NoError(t, db.Create(&models.User{ID: 2, Nickname: "合成收件人", PasswordHash: "synthetic", AccountStatus: "active"}).Error)
	require.NoError(t, db.Model(&post).Update("author_id", 2).Error)
	action, err := s.Propose(context.Background(), b, integrationReplyProposal(post))
	require.NoError(t, err)
	decision := integrationDecision(t, s, action)
	for i := 0; i < 2; i++ {
		_, err = s.Decide(context.Background(), 1, action.ID, decision)
		require.NoError(t, err)
	}
	var notifications []models.Notification
	require.NoError(t, db.Find(&notifications).Error)
	require.Len(t, notifications, 1)
	require.EqualValues(t, 2, notifications[0].UserID)
	require.EqualValues(t, 1, notifications[0].FromUID)
	require.Equal(t, "reply", notifications[0].Type)
	require.Equal(t, post.ID, notifications[0].PostID)
}
