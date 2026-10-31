package handlers

import (
	"context"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func TestIntegrationAnonymousPublicAndPrivateCheckInHTTP(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{Logger: logger.Discard})
	require.NoError(t, err)
	pool, _ := db.DB()
	pool.SetMaxOpenConns(1)
	t.Cleanup(func() { pool.Close() })
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}, &models.AcademicIdentityBinding{}, &models.IntegrationBinding{}, &models.IntegrationDeviceRequest{}, &models.IntegrationCredential{}, &models.IntegrationAction{}, &models.IntegrationAudit{}, &models.IntegrationRateBucket{}, &models.Post{}, &models.Reply{}, &models.PostImage{}, &models.ReplyImage{}, &models.File{}, &models.WaterSection{}, &models.CheckIn{}, &models.UserCheckInStat{}, &models.UserExperienceLedger{}))
	require.NoError(t, db.Create(&models.User{ID: 1, Nickname: "合成本人", AccountStatus: "active"}).Error)
	require.NoError(t, db.Create(&models.AcademicIdentityBinding{UserID: 1, ProviderID: models.AcademicProviderUndergraduate, StudentID: "synthetic-daily", VerifiedAt: time.Now(), VerificationMethod: "school_profile", VerificationVersion: "v1"}).Error)
	for _, document := range []string{models.LegalDocumentUserAgreement, models.LegalDocumentPrivacyPolicy} {
		require.NoError(t, db.Create(&models.UserLegalConsent{UserID: 1, Document: document, Version: models.LegalDocumentVersion, AcceptedAt: time.Now()}).Error)
	}
	h := NewIntegrationHandler(db, IntegrationOptions{})
	router := gin.New()
	h.Register(router, "synthetic-secret")
	post := models.Post{AuthorID: 1, Title: "公开合成帖子", Content: "真实正文", Contact: "private-contact", BoardID: models.BoardShuitie, Status: models.PostStatusNormal, ContentKind: models.PostContentKindNormal}
	require.NoError(t, db.Create(&post).Error)
	send := func(method, path, token, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		if body != "" {
			r.Header.Set("Content-Type", "application/json")
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return w
	}
	w := send("GET", fmt.Sprintf("/api/integrations/v1/public/community/posts/%d", post.ID), "", "")
	require.Equal(t, 200, w.Code, w.Body.String())
	require.Contains(t, w.Body.String(), "公开合成帖子")
	require.NotContains(t, w.Body.String(), "private-contact")
	var current models.Post
	require.NoError(t, db.First(&current, post.ID).Error)
	require.Zero(t, current.ViewCount)
	for _, path := range []string{"/api/integrations/v1/binding", "/api/integrations/v1/me/checkin"} {
		require.Equal(t, 401, send("GET", path, "", "").Code)
	}
	require.Equal(t, 404, send("POST", "/api/integrations/v1/public/me/checkin", "", "").Code)
	ctx := context.Background()
	device, err := h.auth.RequestDevice(ctx, uuid.NewString(), "合成安装", services.IntegrationCheckInScope)
	require.NoError(t, err)
	consent, err := h.auth.LookupConsent(ctx, 1, device.UserCode)
	require.NoError(t, err)
	binding, err := h.auth.DecideConsent(ctx, 1, consent.ID, services.IntegrationConsentDecision{Allow: true, Scopes: consent.RequestedScopes, Nonce: consent.Nonce})
	require.NoError(t, err)
	const token = "sa_synthetic_daily_http"
	require.NoError(t, db.Create(&models.IntegrationCredential{ID: uuid.NewString(), BindingID: binding.ID, TokenHash: services.IntegrationSecretHash(token), Kind: "access", Epoch: binding.Epoch, ExpiresAt: time.Now().Add(time.Hour)}).Error)
	for _, body := range []string{`{"user_id":2}`, `{"date":"2026-10-01"}`, `{"makeup":true}`} {
		require.Equal(t, 422, send("POST", "/api/integrations/v1/me/checkin", token, body).Code)
	}
	require.Equal(t, 422, send("POST", "/api/integrations/v1/me/checkin?user_id=2", token, "{}").Code)
	w = send("GET", "/api/integrations/v1/me/checkin", token, "")
	require.Equal(t, 200, w.Code, w.Body.String())
	require.Contains(t, w.Body.String(), `"checked_in":false`)
	w = send("POST", "/api/integrations/v1/me/checkin", token, "{}")
	require.Equal(t, 200, w.Code, w.Body.String())
	require.Contains(t, w.Body.String(), `"already":false`)
	w = send("POST", "/api/integrations/v1/me/checkin", token, "")
	require.Equal(t, 200, w.Code, w.Body.String())
	require.Contains(t, w.Body.String(), `"already":true`)
	require.NoError(t, h.auth.Revoke(ctx, 1, binding.ID))
	require.Equal(t, 401, send("POST", "/api/integrations/v1/me/checkin", token, "{}").Code)
	// 账号撤权不影响任何人的公开读取，隐藏来源则立刻不可读。
	require.Equal(t, 200, send("GET", "/api/integrations/v1/public/community/posts", "", "").Code)
	require.NoError(t, db.Model(&post).Update("status", models.PostStatusModeratedHidden).Error)
	require.Equal(t, 404, send("GET", fmt.Sprintf("/api/integrations/v1/public/community/posts/%d", post.ID), "", "").Code)
}
