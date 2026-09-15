package middleware

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// newCommunityRulesTestDB 造一个已通过登录协议门禁、但未必确认过社区规则的用户。
func newCommunityRulesTestUser(t *testing.T, db *gorm.DB, rulesAccepted bool) (models.User, string) {
	t.Helper()
	user := models.User{StudentID: "community-rules-user", PasswordHash: "hash"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("创建用户失败: %v", err)
	}
	now := time.Now()
	for _, document := range models.RequiredLegalDocuments(false) {
		if err := db.Create(&models.UserLegalConsent{
			UserID: user.ID, Document: document, Version: models.LegalDocumentVersion,
			Scene: "register", AcceptedAt: now, AcknowledgementType: "explicit_acceptance", Scope: "account",
		}).Error; err != nil {
			t.Fatalf("写入登录协议确认失败: %v", err)
		}
	}
	if rulesAccepted {
		if err := db.Create(&models.UserLegalConsent{
			UserID: user.ID, Document: models.LegalDocumentCommunityRules, Version: models.LegalDocumentVersion,
			Scene: "first_write", AcceptedAt: now, AcknowledgementType: "rules_acceptance", Scope: "community",
		}).Error; err != nil {
			t.Fatalf("写入社区规则确认失败: %v", err)
		}
	}
	token, err := GenerateToken(user.ID, string(models.RoleUser), user.TokenVersion, "community-rules-secret")
	if err != nil {
		t.Fatalf("生成令牌失败: %v", err)
	}
	return user, token
}

func newCommunityRulesTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	clearTokenVersionCacheForTest()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}); err != nil {
		t.Fatalf("迁移表失败: %v", err)
	}
	return db
}

// 与 main.go 中 canteenAuth 的挂载方式一致：AuthMiddleware 之后接内容门禁。
func newCanteenLikeRouter(db *gorm.DB) *gin.Engine {
	router := gin.New()
	group := router.Group("/api/canteens")
	group.Use(AuthMiddleware(db, "community-rules-secret"), RequireCommunityRules(db))
	group.POST("/:id/reviews", func(c *gin.Context) { c.Status(http.StatusNoContent) })
	group.GET("/:id/reviews", func(c *gin.Context) { c.Status(http.StatusOK) })
	return router
}

func TestRequireCommunityRulesBlocksCanteenReviewWithoutAcceptance(t *testing.T) {
	previousMode := legalConsentEnforcement
	SetLegalConsentEnforcement(LegalConsentEnforcementHard)
	defer SetLegalConsentEnforcement(previousMode)

	db := newCommunityRulesTestDB(t)
	_, token := newCommunityRulesTestUser(t, db, false)

	request := httptest.NewRequest(http.MethodPost, "/api/canteens/7/reviews", strings.NewReader(`{"content":"好吃"}`))
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	newCanteenLikeRouter(db).ServeHTTP(response, request)

	if response.Code != http.StatusForbidden {
		t.Fatalf("未确认社区规则时发食堂评价应被拒绝，实际 status=%d body=%s", response.Code, response.Body.String())
	}
	if !strings.Contains(response.Body.String(), "community_rules_required") {
		t.Fatalf("应返回 community_rules_required，实际 %s", response.Body.String())
	}
}

func TestRequireCommunityRulesAllowsCanteenReviewAfterAcceptance(t *testing.T) {
	previousMode := legalConsentEnforcement
	SetLegalConsentEnforcement(LegalConsentEnforcementHard)
	defer SetLegalConsentEnforcement(previousMode)

	db := newCommunityRulesTestDB(t)
	_, token := newCommunityRulesTestUser(t, db, true)

	request := httptest.NewRequest(http.MethodPost, "/api/canteens/7/reviews", strings.NewReader(`{"content":"好吃"}`))
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	newCanteenLikeRouter(db).ServeHTTP(response, request)

	if response.Code != http.StatusNoContent {
		t.Fatalf("已确认社区规则时应放行，实际 status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestRequireCommunityRulesDoesNotGateReadRequests(t *testing.T) {
	previousMode := legalConsentEnforcement
	SetLegalConsentEnforcement(LegalConsentEnforcementHard)
	defer SetLegalConsentEnforcement(previousMode)

	db := newCommunityRulesTestDB(t)
	_, token := newCommunityRulesTestUser(t, db, false)

	request := httptest.NewRequest(http.MethodGet, "/api/canteens/7/reviews", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	newCanteenLikeRouter(db).ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("只读请求不应触发社区规则门禁，实际 status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestRequireCommunityRulesOnlyEnforcedInHardMode(t *testing.T) {
	previousMode := legalConsentEnforcement
	defer SetLegalConsentEnforcement(previousMode)

	db := newCommunityRulesTestDB(t)
	_, token := newCommunityRulesTestUser(t, db, false)

	for _, mode := range []string{LegalConsentEnforcementSoft, LegalConsentEnforcementOff} {
		SetLegalConsentEnforcement(mode)
		request := httptest.NewRequest(http.MethodPost, "/api/canteens/7/reviews", strings.NewReader(`{"content":"好吃"}`))
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		newCanteenLikeRouter(db).ServeHTTP(response, request)

		if response.Code != http.StatusNoContent {
			t.Fatalf("%s 模式下不应拦截，实际 status=%d body=%s", mode, response.Code, response.Body.String())
		}
	}
}

// 门禁查询失败必须 fail-closed，不能因为读不到确认记录就放行。
func TestRequireCommunityRulesFailsClosedOnLookupError(t *testing.T) {
	previousMode := legalConsentEnforcement
	SetLegalConsentEnforcement(LegalConsentEnforcementHard)
	defer SetLegalConsentEnforcement(previousMode)

	db := newCommunityRulesTestDB(t)
	user, _ := newCommunityRulesTestUser(t, db, true)
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("获取连接失败: %v", err)
	}
	if err := sqlDB.Close(); err != nil {
		t.Fatalf("关闭连接失败: %v", err)
	}

	// 单独挂载门禁（身份由前置中间件提供），确保断言的是门禁本身的失败方向。
	router := gin.New()
	router.POST("/api/canteens/:id/reviews",
		func(c *gin.Context) { c.Set("user_id", user.ID) },
		RequireCommunityRules(db),
		func(c *gin.Context) { c.Status(http.StatusNoContent) },
	)

	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/api/canteens/7/reviews", strings.NewReader(`{"content":"好吃"}`)))

	if response.Code != http.StatusInternalServerError {
		t.Fatalf("查询失败时应返回 5xx 而不是放行，实际 status=%d body=%s", response.Code, response.Body.String())
	}
}
