package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func remediationAuthFixture(t *testing.T) (*AuthHandler, *gorm.DB, models.User, *accountSecurityTestMailer) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	require.NoError(t, err)
	return remediationAuthFixtureForDB(t, db)
}

func remediationAuthFixtureForDB(t *testing.T, db *gorm.DB) (*AuthHandler, *gorm.DB, models.User, *accountSecurityTestMailer) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.AccountLoginAlias{}, &models.LoginThrottleRecord{},
		&models.RefreshToken{}, &models.UserLegalConsent{}, &models.AccountSecurityAuditLog{}, &models.SecurityEvent{},
		&models.EmailVerificationChallenge{}, &models.EmailVerificationRequest{}, &models.VerificationAttempt{}, &models.VerificationAttemptBucket{}))
	now := time.Now()
	hash, err := bcrypt.GenerateFromPassword([]byte("old-password"), bcrypt.MinCost)
	require.NoError(t, err)
	user := models.User{Email: "reset@example.com", EmailVerifiedAt: &now, QQ: "12345678", PasswordHash: string(hash), AccountStatus: "active", Role: models.RoleUser}
	require.NoError(t, db.Create(&user).Error)
	require.NoError(t, db.Create(&models.AccountLoginAlias{UserID: user.ID, Value: "202600001", Source: "legacy_binding_snapshot"}).Error)
	mailer := &accountSecurityTestMailer{}
	verification := services.NewEmailVerificationService(db, mailer, "test-secret", time.Now)
	h := NewAuthHandlerWithEmailVerification(db, "test-jwt-secret", verification)
	h.SetSecurityEventService(services.NewSecurityEventService(db, "test-security-secret", time.Now))
	return h, db, user, mailer
}

func remediationRequest(router http.Handler, path string, payload interface{}, ip, ua string) *httptest.ResponseRecorder {
	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Auth-Transport", "cookie")
	req.Header.Set("User-Agent", ua)
	req.RemoteAddr = ip + ":1234"
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	return rec
}

func TestEmailResetClearsPersistentAliasesAndPreservesSourceProtection(t *testing.T) {
	h, db, user, mailer := remediationAuthFixture(t)
	testEmailResetRecovery(t, h, db, user, mailer)
}

func testEmailResetRecovery(t *testing.T, h *AuthHandler, db *gorm.DB, user models.User, mailer *accountSecurityTestMailer) {
	t.Helper()
	aliases := []string{user.Email, user.QQ, "202600001"}
	now := time.Now()
	for _, account := range append(aliases, "other@example.com") {
		for i := 0; i < 3; i++ {
			h.registerLoginFailure(loginThrottleScope("account", account), now)
		}
	}
	// 同时覆盖数据库故障时留下的进程内回退计数。
	for i := 0; i < 3; i++ {
		registerLoginFailure(loginThrottleScope("account", user.Email), now)
	}
	t.Cleanup(func() { clearLoginFailures(loginThrottleScope("account", user.Email)) })
	for i := 0; i < 10; i++ {
		h.registerLoginFailure(loginThrottleScope("ip", "203.0.113.9"), now)
	}
	ctx, _ := gin.CreateTestContext(httptest.NewRecorder())
	ctx.Request = httptest.NewRequest(http.MethodPost, "/api/login", nil)
	oldRefresh, family, err := h.issueRefreshSession(user.ID, ctx)
	require.NoError(t, err)
	oldAccess, err := middleware.GenerateToken(user.ID, string(user.Role), user.TokenVersion, "test-jwt-secret", family)
	require.NoError(t, err)
	require.NoError(t, h.emailVerification.Request(user.Email, models.EmailVerificationPurposeResetPassword, &user.ID, "203.0.113.8"))
	router := gin.New()
	require.NoError(t, router.SetTrustedProxies(nil))
	router.POST("/api/password/email/reset", h.ResetPasswordByEmail)
	router.POST("/api/login", h.Login)
	router.POST("/api/refresh", h.Refresh)
	router.GET("/api/me", middleware.AuthMiddleware(db, "test-jwt-secret"), func(c *gin.Context) { c.Status(http.StatusOK) })
	payload := map[string]string{"email": " RESET@EXAMPLE.COM ", "code": mailer.codes[user.Email+":"+models.EmailVerificationPurposeResetPassword], "new_password": "new-password"}
	reset := remediationRequest(router, "/api/password/email/reset", payload, "203.0.113.8", "browser")
	require.Equal(t, http.StatusOK, reset.Code, reset.Body.String())
	_, memoryLocked := currentLoginLock(loginThrottleScope("account", user.Email), time.Now())
	require.False(t, memoryLocked)
	for _, account := range aliases {
		_, locked := h.loginLock(loginThrottleScope("account", account), time.Now())
		require.False(t, locked, account)
		login := remediationRequest(router, "/api/login", map[string]string{"account": account, "password": "new-password"}, "203.0.113.8", "browser")
		require.Equal(t, http.StatusOK, login.Code, login.Body.String())
		require.NotContains(t, login.Body.String(), `"token"`)
		require.NotContains(t, login.Body.String(), `"refresh_token"`)
		require.NotEmpty(t, login.Result().Cookies())
	}
	for _, scope := range []string{loginThrottleScope("account", "other@example.com"), loginThrottleScope("ip", "203.0.113.9")} {
		_, locked := h.loginLock(scope, time.Now())
		require.True(t, locked)
	}
	var tokens []models.RefreshToken
	require.NoError(t, db.Where("token_family = ?", family).Find(&tokens).Error)
	require.NotNil(t, tokens[0].RevokedAt)
	refresh := remediationRequest(router, "/api/refresh", map[string]string{"refresh_token": oldRefresh}, "203.0.113.8", "browser")
	require.Equal(t, http.StatusUnauthorized, refresh.Code)
	req := httptest.NewRequest(http.MethodGet, "/api/me", nil)
	req.Header.Set("Authorization", "Bearer "+oldAccess)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	require.Equal(t, http.StatusUnauthorized, rec.Code)
	wrong := remediationRequest(router, "/api/login", map[string]string{"account": user.Email, "password": "old-password"}, "203.0.113.8", "browser")
	require.Equal(t, http.StatusUnauthorized, wrong.Code)
}

func TestResetDoesNotClearAmbiguousOrOtherOwnersLoginNames(t *testing.T) {
	h, db, user, _ := remediationAuthFixture(t)
	other := models.User{AccountStatus: "active", PasswordHash: "hash", Email: "other@example.com"}
	require.NoError(t, db.Create(&other).Error)
	for _, alias := range []models.AccountLoginAlias{
		{UserID: other.ID, Value: "202600001", Source: "legacy_binding_snapshot"},
		{UserID: other.ID, Value: user.QQ, Source: "legacy_binding_snapshot"},
	} {
		require.NoError(t, db.Create(&alias).Error)
	}
	now := time.Now()
	for _, account := range []string{user.Email, user.QQ, "202600001"} {
		for i := 0; i < 3; i++ {
			h.registerLoginFailure(loginThrottleScope("account", account), now)
		}
	}
	h.clearUserLoginFailures(user)
	_, locked := h.loginLock(loginThrottleScope("account", user.Email), now)
	require.False(t, locked)
	for _, account := range []string{user.QQ, "202600001"} {
		_, locked := h.loginLock(loginThrottleScope("account", account), now)
		require.True(t, locked, account)
	}
}

func TestInvalidResetPreservesPasswordSessionsAndAccountLock(t *testing.T) {
	h, db, user, _ := remediationAuthFixture(t)
	for i := 0; i < 3; i++ {
		h.registerLoginFailure(loginThrottleScope("account", user.Email), time.Now())
	}
	ctx, _ := gin.CreateTestContext(httptest.NewRecorder())
	ctx.Request = httptest.NewRequest(http.MethodPost, "/api/login", nil)
	_, family, err := h.issueRefreshSession(user.ID, ctx)
	require.NoError(t, err)
	r := gin.New()
	r.POST("/api/password/email/reset", h.ResetPasswordByEmail)
	rec := remediationRequest(r, "/api/password/email/reset", map[string]string{"email": user.Email, "code": "000000", "new_password": "new-password"}, "203.0.113.8", "browser")
	require.Equal(t, http.StatusBadRequest, rec.Code)
	var stored models.User
	require.NoError(t, db.First(&stored, user.ID).Error)
	require.Equal(t, user.PasswordHash, stored.PasswordHash)
	require.Equal(t, user.TokenVersion, stored.TokenVersion)
	_, locked := h.loginLock(loginThrottleScope("account", user.Email), time.Now())
	require.True(t, locked)
	var token models.RefreshToken
	require.NoError(t, db.Where("token_family = ?", family).First(&token).Error)
	require.Nil(t, token.RevokedAt)
}

func TestNativeLoginKeepsBearerContractAndCookieRefreshOmitsTokens(t *testing.T) {
	h, _, user, _ := remediationAuthFixture(t)
	r := gin.New()
	r.Use(middleware.BrowserOriginGuard())
	r.POST("/api/login", h.Login)
	r.POST("/api/refresh", h.Refresh)
	body, _ := json.Marshal(map[string]string{"account": user.Email, "password": "old-password"})
	req := httptest.NewRequest(http.MethodPost, "/api/login", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	require.Equal(t, http.StatusOK, rec.Code, rec.Body.String())
	var native map[string]interface{}
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &native))
	require.NotEmpty(t, native["token"])
	require.NotEmpty(t, native["refresh_token"])
	refresh := httptest.NewRequest(http.MethodPost, "/api/refresh", nil)
	for _, cookie := range rec.Result().Cookies() {
		refresh.AddCookie(cookie)
	}
	refresh.Header.Set("X-Auth-Transport", "cookie")
	refreshed := httptest.NewRecorder()
	r.ServeHTTP(refreshed, refresh)
	require.Equal(t, http.StatusOK, refreshed.Code, refreshed.Body.String())
	require.NotContains(t, refreshed.Body.String(), `"token"`)
	require.NotContains(t, refreshed.Body.String(), `"refresh_token"`)
}

func TestAdminNewDeviceProducesActionableHighSeverityEvent(t *testing.T) {
	h, db, user, _ := remediationAuthFixture(t)
	require.NoError(t, db.Model(&user).Update("role", models.RoleAdmin).Error)
	r := gin.New()
	r.POST("/api/login", h.Login)
	for _, ua := range []string{"first-admin-device", "second-admin-device"} {
		rec := remediationRequest(r, "/api/login", map[string]string{"account": user.Email, "password": "old-password"}, "203.0.113.8", ua)
		require.Equal(t, http.StatusOK, rec.Code, rec.Body.String())
	}
	var event models.SecurityEvent
	require.NoError(t, db.Where("event_type = ?", "admin_login_new_device").First(&event).Error)
	require.Equal(t, models.SecuritySeverityHigh, event.Severity)
	require.True(t, models.SecurityEventActionable(event.EventType))
}

func TestLoginTreatsSQLPayloadAsUnmatchedAccount(t *testing.T) {
	for _, account := range []string{"' OR '1'='1", "reset@example.com' OR '1'='1", "202600001'; DROP TABLE users; --"} {
		t.Run(account, func(t *testing.T) {
			h, db, _, _ := remediationAuthFixture(t)
			r := gin.New()
			r.POST("/api/login", h.Login)
			rec := remediationRequest(r, "/api/login", map[string]string{"account": account, "password": "old-password"}, "203.0.113.8", "browser")
			require.Equal(t, http.StatusUnauthorized, rec.Code, rec.Body.String())
			var users, sessions int64
			require.NoError(t, db.Model(&models.User{}).Count(&users).Error)
			require.NoError(t, db.Model(&models.RefreshToken{}).Count(&sessions).Error)
			require.Equal(t, int64(1), users)
			require.Zero(t, sessions)
		})
	}
}

func TestLoginSuccessAuditAndNewDevice(t *testing.T) {
	h, db, user, _ := remediationAuthFixture(t)
	router := gin.New()
	require.NoError(t, router.SetTrustedProxies(nil))
	router.Use(middleware.RequestTraceMiddleware())
	router.POST("/api/login", h.Login)
	for _, ua := range []string{"device-one", "device-one", "device-two"} {
		rec := remediationRequest(router, "/api/login", map[string]string{"account": user.Email, "password": "old-password"}, "203.0.113.8", ua)
		require.Equal(t, http.StatusOK, rec.Code, rec.Body.String())
	}
	var audits []models.AccountSecurityAuditLog
	require.NoError(t, db.Where("user_id = ? AND action = ?", user.ID, "login_success").Find(&audits).Error)
	require.Len(t, audits, 3)
	for _, audit := range audits {
		require.Contains(t, audit.Metadata, `"request_id"`)
		require.NotContains(t, audit.Metadata, user.Email)
		require.NotContains(t, audit.Metadata, "203.0.113.8")
		require.NotContains(t, audit.Metadata, "old-password")
		require.NotContains(t, audit.Metadata, "device-one")
	}
	var events []models.SecurityEvent
	require.NoError(t, db.Where("event_type = ?", "login_new_device").Find(&events).Error)
	require.Len(t, events, 1)
	require.Equal(t, 1, events[0].AttemptCount)
	wrong := remediationRequest(router, "/api/login", map[string]string{"account": user.Email, "password": "wrong-password"}, "203.0.113.8", "device-three")
	require.Equal(t, http.StatusUnauthorized, wrong.Code)
	var count int64
	require.NoError(t, db.Model(&models.AccountSecurityAuditLog{}).Where("action = ?", "login_success").Count(&count).Error)
	require.Equal(t, int64(3), count)
}
