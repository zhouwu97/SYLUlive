package middleware

import (
	"encoding/json"
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

func TestTokenFromRequestPrefersAuthorizationHeader(t *testing.T) {
	gin.SetMode(gin.TestMode)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Authorization", "Bearer header-token")
	req.AddCookie(&http.Cookie{Name: "jwt", Value: "cookie-token"})

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = req

	if got := tokenFromRequest(c); got != "header-token" {
		t.Fatalf("tokenFromRequest() = %q, want header-token", got)
	}
}

func TestTokenFromRequestFallsBackToCookie(t *testing.T) {
	gin.SetMode(gin.TestMode)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.AddCookie(&http.Cookie{Name: "jwt", Value: "cookie-token"})

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = req

	if got := tokenFromRequest(c); got != "cookie-token" {
		t.Fatalf("tokenFromRequest() = %q, want cookie-token", got)
	}
}

func TestAuthMiddlewareErrorIncludesMachineCode(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	router := gin.New()
	router.GET("/private", AuthMiddleware(db, "secret"), func(c *gin.Context) {
		c.Status(http.StatusOK)
	})

	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/private", nil))

	if response.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d, want %d", response.Code, http.StatusUnauthorized)
	}
	var body map[string]string
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body["error"] == "" || body["code"] != "authentication_required" {
		t.Fatalf("unexpected auth error body: %#v", body)
	}
}

func TestAdminMiddlewareErrorIncludesMachineCode(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.GET("/admin", func(c *gin.Context) {
		c.Set("role", string(models.RoleUser))
	}, AdminMiddleware(), func(c *gin.Context) {
		c.Status(http.StatusOK)
	})

	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/admin", nil))

	if response.Code != http.StatusForbidden {
		t.Fatalf("status=%d, want %d", response.Code, http.StatusForbidden)
	}
	var body map[string]string
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body["error"] == "" || body["code"] != "admin_required" {
		t.Fatalf("unexpected admin error body: %#v", body)
	}
}

func TestTokenVersionCacheUsesTTL(t *testing.T) {
	clearTokenVersionCacheForTest()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}); err != nil {
		t.Fatalf("migrate user: %v", err)
	}
	user := models.User{
		ID:           1,
		StudentID:    "student-1",
		PasswordHash: "hash",
		TokenVersion: 1,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}

	version, err := getCachedTokenVersion(db, user.ID)
	if err != nil || version != 1 {
		t.Fatalf("first version=%d err=%v", version, err)
	}
	if err := db.Model(&models.User{}).Where("id = ?", user.ID).Update("token_version", 2).Error; err != nil {
		t.Fatalf("update token version: %v", err)
	}
	version, err = getCachedTokenVersion(db, user.ID)
	if err != nil || version != 1 {
		t.Fatalf("cached version=%d err=%v", version, err)
	}

	clearTokenVersionCacheForTest()
	version, err = getCachedTokenVersion(db, user.ID)
	if err != nil || version != 2 {
		t.Fatalf("refreshed version=%d err=%v", version, err)
	}
}

func TestAuthMiddlewareHardModeBlocksRevokedConsentButKeepsPrivacyAccess(t *testing.T) {
	clearTokenVersionCacheForTest()
	previousMode := legalConsentEnforcement
	SetLegalConsentEnforcement(LegalConsentEnforcementHard)
	defer SetLegalConsentEnforcement(previousMode)
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}); err != nil {
		t.Fatalf("migrate user: %v", err)
	}
	now := time.Now()
	user := models.User{StudentID: "withdrawn-user", PasswordHash: "hash", LegalConsentRevokedAt: &now}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	token, err := GenerateToken(user.ID, string(models.RoleUser), user.TokenVersion, "secret")
	if err != nil {
		t.Fatalf("generate token: %v", err)
	}
	router := gin.New()
	router.GET("/api/private", AuthMiddleware(db, "secret"), func(c *gin.Context) { c.Status(http.StatusOK) })
	router.GET("/api/user/privacy/data", AuthMiddleware(db, "secret"), func(c *gin.Context) { c.Status(http.StatusOK) })

	privateRequest := httptest.NewRequest(http.MethodGet, "/api/private", nil)
	privateRequest.Header.Set("Authorization", "Bearer "+token)
	privateResponse := httptest.NewRecorder()
	router.ServeHTTP(privateResponse, privateRequest)
	if privateResponse.Code != http.StatusForbidden || !strings.Contains(privateResponse.Body.String(), "legal_consent_withdrawn") {
		t.Fatalf("private status=%d body=%s", privateResponse.Code, privateResponse.Body.String())
	}
	privacyRequest := httptest.NewRequest(http.MethodGet, "/api/user/privacy/data", nil)
	privacyRequest.Header.Set("Authorization", "Bearer "+token)
	privacyResponse := httptest.NewRecorder()
	router.ServeHTTP(privacyResponse, privacyRequest)
	if privacyResponse.Code != http.StatusOK {
		t.Fatalf("privacy status=%d body=%s", privacyResponse.Code, privacyResponse.Body.String())
	}
}

func TestAuthMiddlewareSoftModeAllowsLegacyUser(t *testing.T) {
	clearTokenVersionCacheForTest()
	previousMode := legalConsentEnforcement
	SetLegalConsentEnforcement(LegalConsentEnforcementSoft)
	defer SetLegalConsentEnforcement(previousMode)
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}); err != nil {
		t.Fatalf("migrate user: %v", err)
	}
	user := models.User{StudentID: "legacy-user", PasswordHash: "hash"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	token, err := GenerateToken(user.ID, string(models.RoleUser), user.TokenVersion, "secret")
	if err != nil {
		t.Fatalf("generate token: %v", err)
	}
	router := gin.New()
	router.GET("/api/private", AuthMiddleware(db, "secret"), func(c *gin.Context) { c.Status(http.StatusNoContent) })
	request := httptest.NewRequest(http.MethodGet, "/api/private", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("soft mode status=%d body=%s", response.Code, response.Body.String())
	}
}
