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
	if body["message"] == "" || body["code"] != "authentication_required" ||
		body["request_id"] == "" {
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
	if body["message"] == "" || body["code"] != "admin_required" ||
		body["request_id"] == "" {
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

func TestAuthMiddlewareRequiresEduDataConsentForAuthorizedUser(t *testing.T) {
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
		t.Fatalf("migrate database: %v", err)
	}
	user := models.User{StudentID: "edu-consent-user", PasswordHash: "hash", EduAuthorized: true, EduBound: true}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	for _, document := range models.RequiredLegalDocuments(false) {
		if err := db.Create(&models.UserLegalConsent{
			UserID: user.ID, Document: document, Version: models.LegalDocumentVersion,
			AcceptedAt: time.Now(), Scene: "registration",
		}).Error; err != nil {
			t.Fatalf("create base consent %s: %v", document, err)
		}
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
	if response.Code != http.StatusForbidden || !strings.Contains(response.Body.String(), "legal_consent_required") {
		t.Fatalf("missing edu consent should be blocked: status=%d body=%s", response.Code, response.Body.String())
	}

	if err := db.Create(&models.UserLegalConsent{
		UserID: user.ID, Document: models.LegalDocumentEduDataConsent, Version: models.LegalDocumentVersion,
		AcceptedAt: time.Now(), Scope: "education", Scene: "edu_binding",
	}).Error; err != nil {
		t.Fatalf("create edu consent: %v", err)
	}
	clearTokenVersionCacheForTest()
	response = httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("valid edu consent should pass: status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestOptionalAuthMiddlewareOffModePreservesIdentity(t *testing.T) {
	assertOptionalAuthIdentity(t, LegalConsentEnforcementOff, models.LegalConsentStateRequired, true)
}

func TestOptionalAuthMiddlewareSoftModePreservesLegacyIdentity(t *testing.T) {
	assertOptionalAuthIdentity(t, LegalConsentEnforcementSoft, models.LegalConsentStateRequired, true)
}

func TestOptionalAuthMiddlewareHardModeTreatsRevokedUserAsAnonymous(t *testing.T) {
	assertOptionalAuthIdentity(t, LegalConsentEnforcementHard, models.LegalConsentStateRevoked, false)
}

func TestOptionalAuthMiddlewareHardModeKeepsActiveUserIdentity(t *testing.T) {
	assertOptionalAuthIdentity(t, LegalConsentEnforcementHard, models.LegalConsentStateActive, true)
}

func assertOptionalAuthIdentity(t *testing.T, enforcement string, consentState models.LegalConsentState, wantIdentity bool) {
	t.Helper()
	clearTokenVersionCacheForTest()
	previousMode := legalConsentEnforcement
	SetLegalConsentEnforcement(enforcement)
	defer SetLegalConsentEnforcement(previousMode)

	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}); err != nil {
		t.Fatalf("migrate user: %v", err)
	}

	user := models.User{StudentID: "optional-auth-user", PasswordHash: "hash"}
	if consentState == models.LegalConsentStateRevoked {
		now := time.Now()
		user.LegalConsentRevokedAt = &now
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	if consentState == models.LegalConsentStateActive {
		for _, document := range models.RequiredLegalDocuments(false) {
			consent := models.UserLegalConsent{
				UserID:     user.ID,
				Document:   document,
				Version:    models.LegalDocumentVersion,
				AcceptedAt: time.Now(),
			}
			if err := db.Create(&consent).Error; err != nil {
				t.Fatalf("create consent %s: %v", document, err)
			}
		}
	}

	token, err := GenerateToken(user.ID, string(models.RoleUser), user.TokenVersion, "secret")
	if err != nil {
		t.Fatalf("generate token: %v", err)
	}
	router := gin.New()
	router.GET("/public", OptionalAuthMiddleware(db, "secret"), func(c *gin.Context) {
		_, exists := c.Get("user_id")
		c.JSON(http.StatusOK, gin.H{"has_identity": exists})
	})
	request := httptest.NewRequest(http.MethodGet, "/public", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}

	var body struct {
		HasIdentity bool `json:"has_identity"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.HasIdentity != wantIdentity {
		t.Fatalf("mode=%s consent=%s has_identity=%t want=%t", enforcement, consentState, body.HasIdentity, wantIdentity)
	}
}
