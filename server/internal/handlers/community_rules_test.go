package handlers

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

func TestCommunityRulesConsentAllowsRepeatedLikesAndSurvivesLegalRenewal(t *testing.T) {
	gin.SetMode(gin.TestMode)
	middleware.SetLegalConsentEnforcement(middleware.LegalConsentEnforcementHard)
	t.Cleanup(func() { middleware.SetLegalConsentEnforcement(middleware.LegalConsentEnforcementSoft) })
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}, &models.Post{}, &models.Like{}); err != nil {
		t.Fatal(err)
	}
	if err := models.EnsureIdempotencySchema(db); err != nil {
		t.Fatal(err)
	}
	user := models.User{StudentID: "community-consent-student", PasswordHash: "hash", EduAuthorized: true, EduBound: true}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	middleware.InvalidateTokenVersionCache(user.ID)
	t.Cleanup(func() { middleware.InvalidateTokenVersionCache(user.ID) })
	for _, id := range []uint{1, 2, 3} {
		if err := db.Create(&models.Post{ID: id, AuthorID: user.ID, Status: models.PostStatusNormal}).Error; err != nil {
			t.Fatal(err)
		}
	}
	token, err := middleware.GenerateToken(user.ID, string(models.RoleUser), user.TokenVersion, "secret")
	if err != nil {
		t.Fatal(err)
	}
	auth := NewAuthHandler(db, "secret")
	router := gin.New()
	router.Use(middleware.IdempotencyMiddlewareWithJWT(db, "secret"))
	api := router.Group("/api", middleware.AuthMiddleware(db, "secret"))
	api.POST("/user/legal-consents", auth.AcceptLegalConsents)
	api.POST("/user/community-rules", auth.AcceptCommunityRules)
	api.POST("/posts/:id/like", NewLikeHandler(db).LikePost)
	sent := 0
	api.POST("/messages/:id", func(c *gin.Context) { sent++; c.JSON(http.StatusCreated, gin.H{"id": sent}) })
	api.POST("/messages/conversations/:id/read", func(c *gin.Context) { c.Status(http.StatusNoContent) })
	request := func(path, body string, status int) {
		t.Helper()
		req := httptest.NewRequest(http.MethodPost, "/api"+path, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		if path == "/messages/2" {
			req.Header.Set("Idempotency-Key", "same-pending-message")
		}
		response := httptest.NewRecorder()
		router.ServeHTTP(response, req)
		if response.Code != status {
			t.Fatalf("%s: status=%d want=%d body=%s", path, response.Code, status, response.Body.String())
		}
	}
	// 旧客户端捆绑提交的社区告知不能替代独立确认。
	legalBody := `{"user_agreement_accepted":true,"privacy_policy_accepted":true,"edu_data_consent_accepted":true,"community_rules_accepted":true}`
	request("/user/legal-consents", `{"user_agreement_accepted":true,"privacy_policy_accepted":true}`, http.StatusBadRequest)
	request("/user/legal-consents", legalBody, http.StatusOK)
	// 本地教务状态丢失时，基础补签应复用已有专项授权，不能卡在缺少勾选项的弹窗。
	request("/user/legal-consents", `{"user_agreement_accepted":true,"privacy_policy_accepted":true}`, http.StatusOK)
	request("/messages/conversations/1/read", "", http.StatusNoContent)
	request("/messages/2", `{"content":"test"}`, http.StatusForbidden)
	request("/messages/2", `{"content":"test"}`, http.StatusForbidden)
	request("/posts/1/like", "", http.StatusForbidden)
	request("/user/community-rules", `{"accepted":false}`, http.StatusBadRequest)
	request("/user/community-rules", `{"accepted":true}`, http.StatusOK)
	request("/messages/2", `{"content":"test"}`, http.StatusCreated)
	request("/messages/2", `{"content":"test"}`, http.StatusCreated)
	if sent != 1 {
		t.Fatalf("确认后原键重试重复发送: %d", sent)
	}
	request("/posts/1/like", "", http.StatusCreated)
	request("/posts/1/like", "", http.StatusOK)
	request("/posts/2/like", "", http.StatusCreated)
	// 补签基础协议不能把已取得的独立社区确认降级成捆绑告知。
	request("/user/legal-consents", legalBody, http.StatusOK)
	request("/posts/3/like", "", http.StatusCreated)
	request("/user/community-rules", `{"accepted":true}`, http.StatusOK)
	var count int64
	if err := db.Model(&models.Like{}).Where("user_id = ?", user.ID).Count(&count).Error; err != nil || count != 3 {
		t.Fatalf("likes=%d err=%v", count, err)
	}
	if err := db.Model(&models.UserLegalConsent{}).Where("user_id = ? AND document = ? AND acknowledgement_type = ? AND scene = ?", user.ID, models.LegalDocumentCommunityRules, "rules_acceptance", "first_write").Count(&count).Error; err != nil || count != 1 {
		t.Fatalf("independent community consents=%d err=%v", count, err)
	}
}
