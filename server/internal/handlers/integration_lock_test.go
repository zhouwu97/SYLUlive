package handlers

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"shenliyuan/internal/community"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func integrationLockDB(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := os.Getenv("INTEGRATION_TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("真实帖子/评论行锁回归需要本机专用 PostgreSQL")
	}
	cfg, err := pgx.ParseConfig(dsn)
	require.NoError(t, err)
	require.Equal(t, "127.0.0.1", cfg.Host)
	require.Equal(t, "sylulive_integration_test", cfg.Database)
	require.Empty(t, cfg.Fallbacks, "禁止测试连接回退到其他主机")
	root, err := gorm.Open(postgres.Open(dsn), &gorm.Config{Logger: logger.Discard})
	require.NoError(t, err)
	schema := "handler_lock_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	require.NoError(t, root.Exec("CREATE SCHEMA "+schema).Error)
	db, err := gorm.Open(postgres.Open(dsn+" search_path="+schema), &gorm.Config{Logger: logger.Discard})
	require.NoError(t, err)
	pool, err := db.DB()
	require.NoError(t, err)
	pool.SetMaxOpenConns(8)
	t.Cleanup(func() {
		_ = pool.Close()
		_ = root.Exec("DROP SCHEMA " + schema + " CASCADE").Error
		parent, _ := root.DB()
		_ = parent.Close()
	})
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}, &models.AcademicIdentityBinding{}, &models.Post{}, &models.Reply{}, &models.ReplyImage{}, &models.Notification{}, &models.WaterSection{}, &models.WaterSectionMute{}, &models.IntegrationBinding{}, &models.IntegrationDeviceRequest{}, &models.IntegrationCredential{}, &models.IntegrationAction{}, &models.IntegrationAudit{}))
	return db
}

type integrationLockActor struct{}

func TestIntegrationPublishAndDeleteActualHandlerLockOrder(t *testing.T) {
	for _, first := range []string{"publisher", "deleter"} {
		t.Run(first, func(t *testing.T) {
			db := integrationLockDB(t)
			gin.SetMode(gin.TestMode)
			require.NoError(t, db.Create(&[]models.User{{ID: 1, Nickname: "合成发布者", PasswordHash: "synthetic", AccountStatus: "active"}, {ID: 2, Nickname: "合成帖子作者", PasswordHash: "synthetic", AccountStatus: "active"}}).Error)
			require.NoError(t, db.Create(&models.AcademicIdentityBinding{UserID: 1, ProviderID: models.AcademicProviderUndergraduate, StudentID: "synthetic-lock", VerifiedAt: time.Now(), VerificationMethod: "school_profile", VerificationVersion: "v1"}).Error)
			for _, doc := range []string{models.LegalDocumentUserAgreement, models.LegalDocumentPrivacyPolicy, models.LegalDocumentCommunityRules} {
				ack := ""
				if doc == models.LegalDocumentCommunityRules {
					ack = "rules_acceptance"
				}
				require.NoError(t, db.Create(&models.UserLegalConsent{UserID: 1, Document: doc, Version: models.LegalDocumentVersion, AcceptedAt: time.Now(), AcknowledgementType: ack}).Error)
			}
			require.NoError(t, db.Create(&models.WaterSection{Slug: "campus_life", Title: "校园生活", Status: "active"}).Error)
			post := models.Post{AuthorID: 2, BoardID: models.BoardShuitie, PostType: "campus_life", Content: "合成帖子", ReplyCount: 1, CreatedAt: time.Now().Add(-time.Hour)}
			require.NoError(t, db.Create(&post).Error)
			target := models.Reply{AuthorID: 2, PostID: post.ID, Content: "待删除的合成评论", Status: models.ReplyStatusNormal}
			require.NoError(t, db.Create(&target).Error)
			auth := services.NewIntegrationAuthService(db)
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			defer cancel()
			device, err := auth.RequestDevice(ctx, uuid.NewString(), "合成安装", "community:read community:propose actions:read_own")
			require.NoError(t, err)
			consent, err := auth.LookupConsent(ctx, 1, device.UserCode)
			require.NoError(t, err)
			binding, err := auth.DecideConsent(ctx, 1, consent.ID, services.IntegrationConsentDecision{Allow: true, Scopes: consent.RequestedScopes, Nonce: consent.Nonce})
			require.NoError(t, err)
			agent := &services.IntegrationActionService{Auth: auth}
			action, err := agent.Propose(ctx, binding, services.IntegrationProposal{OperationID: uuid.NewString(), Kind: "reply", PostID: post.ID, SourceVersion: community.PostDTO(post, 10000).SourceVersion, ReplyToReplyID: target.ID, ReplySourceVersion: community.ReplyDTO(target).SourceVersion, Content: "并发合成回复"})
			require.NoError(t, err)
			preview, err := agent.Preview(ctx, 1, action.ID, nil)
			require.NoError(t, err)
			decision := services.IntegrationActionDecision{Allow: true, Nonce: preview.Nonce, Version: action.Version, PayloadHash: action.PayloadHash}

			held, contender, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
			var heldOnce, contenderOnce, releaseOnce sync.Once
			unblock := func() { releaseOnce.Do(func() { close(release) }) }
			defer unblock()
			var deletionHasPost, wrongOrder atomic.Bool
			require.NoError(t, db.Callback().Query().Before("gorm:query").Register("integration_contender", func(tx *gorm.DB) {
				if tx.Statement.Table == "posts" && tx.Statement.Context.Value(integrationLockActor{}) != first {
					contenderOnce.Do(func() { close(contender) })
				}
			}))
			require.NoError(t, db.Callback().Query().After("gorm:query").Register("integration_post_barrier", func(tx *gorm.DB) {
				_, locking := tx.Statement.Clauses["FOR"]
				if tx.Statement.Table != "posts" || !locking || tx.Error != nil {
					return
				}
				actor := tx.Statement.Context.Value(integrationLockActor{})
				if actor == "deleter" {
					deletionHasPost.Store(true)
				}
				if first == "publisher" && actor == "publisher" {
					heldOnce.Do(func() {
						close(held)
						select {
						case <-release:
						case <-ctx.Done():
							tx.AddError(ctx.Err())
						}
					})
				}
			}))
			require.NoError(t, db.Callback().Update().Before("gorm:update").Register("integration_delete_order", func(tx *gorm.DB) {
				if tx.Statement.Table == "replies" && tx.Statement.Context.Value(integrationLockActor{}) == "deleter" && !deletionHasPost.Load() {
					wrongOrder.Store(true)
				}
			}))
			require.NoError(t, db.Callback().Update().After("gorm:update").Register("integration_delete_barrier", func(tx *gorm.DB) {
				if first == "deleter" && tx.Statement.Table == "replies" && tx.Statement.Context.Value(integrationLockActor{}) == "deleter" {
					heldOnce.Do(func() {
						close(held)
						select {
						case <-release:
						case <-ctx.Done():
							tx.AddError(ctx.Err())
						}
					})
				}
			}))
			published := make(chan error, 1)
			deleted := make(chan *httptest.ResponseRecorder, 1)
			publish := func() {
				_, err := agent.Decide(context.WithValue(ctx, integrationLockActor{}, "publisher"), 1, action.ID, decision)
				published <- err
			}
			deleteReply := func() {
				dctx := context.WithValue(ctx, integrationLockActor{}, "deleter")
				w := httptest.NewRecorder()
				c, _ := gin.CreateTestContext(w)
				c.Request = httptest.NewRequest(http.MethodDelete, fmt.Sprintf("/api/replies/%d", target.ID), nil).WithContext(dctx)
				c.Params = gin.Params{{Key: "id", Value: fmt.Sprint(target.ID)}}
				c.Set("user_id", uint(2))
				c.Set("role", "user")
				NewReplyHandler(db.WithContext(dctx), "", "").Delete(c)
				deleted <- w
			}
			wait := func(ch <-chan struct{}) {
				t.Helper()
				select {
				case <-ch:
				case <-ctx.Done():
					t.Fatal(ctx.Err())
				}
			}
			if first == "publisher" {
				go publish()
				wait(held)
				go deleteReply()
			} else {
				go deleteReply()
				wait(held)
				go publish()
			}
			wait(contender)
			unblock()
			var publishErr error
			select {
			case publishErr = <-published:
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			}
			var response *httptest.ResponseRecorder
			select {
			case response = <-deleted:
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			}
			require.Equal(t, http.StatusOK, response.Code, response.Body.String())
			require.False(t, wrongOrder.Load(), "删评必须先持有帖子锁")
			var count int64
			require.NoError(t, db.Model(&models.Notification{}).Count(&count).Error)
			if first == "publisher" {
				require.NoError(t, publishErr)
				require.EqualValues(t, 1, count)
			} else {
				require.EqualError(t, publishErr, "source_unavailable")
				require.Zero(t, count)
			}
			require.NoError(t, db.First(&target, target.ID).Error)
			require.Equal(t, models.ReplyStatusDeleted, target.Status)
		})
	}
}
