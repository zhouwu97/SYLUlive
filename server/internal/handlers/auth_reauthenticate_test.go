package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"gorm.io/gorm/logger"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

type reauthenticationFixture struct {
	db                 *gorm.DB
	h                  *AuthHandler
	r                  *gin.Engine
	user               models.User
	token, raw, family string
	old                time.Time
}

func newReauthenticationFixture(t *testing.T, db *gorm.DB) reauthenticationFixture {
	t.Helper()
	if db == nil {
		var err error
		db, err = gorm.Open(sqlite.Open(":memory:"), &gorm.Config{Logger: logger.Discard})
		require.NoError(t, err)
		pool, err := db.DB()
		require.NoError(t, err)
		pool.SetMaxOpenConns(1)
		t.Cleanup(func() { _ = pool.Close() })
	}
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.RefreshToken{}, &models.UserLegalConsent{}, &models.LoginThrottleRecord{}, &models.AccountSecurityAuditLog{}))
	hash, err := bcrypt.GenerateFromPassword([]byte("synthetic-password"), bcrypt.MinCost)
	require.NoError(t, err)
	u := models.User{PasswordHash: string(hash), Role: models.RoleUser, AccountStatus: "active"}
	require.NoError(t, db.Create(&u).Error)
	acceptBaseLegalConsents(t, db, u.ID)
	middleware.InvalidateTokenVersionCache(u.ID)
	t.Cleanup(func() { middleware.InvalidateTokenVersionCache(u.ID) })
	h := NewAuthHandler(db, "reauthentication-test-key")
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest("POST", "/api/login", nil)
	raw, family, err := h.issueRefreshSession(u.ID, c)
	require.NoError(t, err)
	token, err := middleware.GenerateToken(u.ID, string(u.Role), u.TokenVersion, h.jwtSecret, family)
	require.NoError(t, err)
	old := time.Now().Add(-time.Hour).Truncate(time.Millisecond)
	require.NoError(t, db.Model(&models.RefreshToken{}).Where("user_id = ?", u.ID).Update("authenticated_at", old).Error)
	r := gin.New()
	r.POST("/api/auth/reauthenticate", middleware.AuthMiddleware(db, h.jwtSecret), h.Reauthenticate)
	return reauthenticationFixture{db: db, h: h, r: r, user: u, token: token, raw: raw, family: family, old: old}
}

func (f reauthenticationFixture) send(t *testing.T, token, body string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest("POST", "/api/auth/reauthenticate", bytes.NewBufferString(body))
	r.RemoteAddr = "192.0.2.12:1234"
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-Auth-Transport", "cookie")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	f.r.ServeHTTP(w, r)
	return w
}

func (f reauthenticationFixture) body(password string) string {
	value, _ := json.Marshal(map[string]interface{}{"expected_user_id": f.user.ID, "password": password})
	return string(value)
}

func TestReauthenticateOnlyUpdatesCurrentSessionAndRefreshPreservesProof(t *testing.T) {
	f := newReauthenticationFixture(t, nil)
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest("POST", "/api/login", nil)
	_, otherFamily, err := f.h.issueRefreshSession(f.user.ID, c)
	require.NoError(t, err)
	require.NoError(t, f.db.Model(&models.RefreshToken{}).Where("token_family = ?", otherFamily).Update("authenticated_at", f.old).Error)
	w := f.send(t, f.token, f.body("synthetic-password"))
	require.Equal(t, 200, w.Code, w.Body.String())
	require.Empty(t, w.Header().Values("Set-Cookie"))
	require.Equal(t, "no-store", w.Header().Get("Cache-Control"))
	require.NotContains(t, w.Body.String(), "token")
	var count int64
	require.NoError(t, f.db.Model(&models.RefreshToken{}).Count(&count).Error)
	require.EqualValues(t, 2, count, "不能因补充密码验证新建登录设备")
	var current, other models.RefreshToken
	require.NoError(t, f.db.Where("token_family = ?", f.family).First(&current).Error)
	require.NoError(t, f.db.Where("token_family = ?", otherFamily).First(&other).Error)
	require.True(t, current.AuthenticatedAt.After(time.Now().Add(-time.Minute)))
	require.WithinDuration(t, f.old, *other.AuthenticatedAt, time.Millisecond)
	var audit models.AccountSecurityAuditLog
	require.NoError(t, f.db.Where("action = ?", "reauthentication_success").First(&audit).Error)
	require.NotContains(t, audit.Metadata, "synthetic-password")
	require.NotContains(t, audit.Metadata, f.family)
	body, _ := json.Marshal(map[string]string{"refresh_token": f.raw})
	w = httptest.NewRecorder()
	c, _ = gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/api/refresh", bytes.NewReader(body))
	c.Request.Header.Set("Content-Type", "application/json")
	f.h.Refresh(c)
	require.Equal(t, 200, w.Code, w.Body.String())
	var rotated models.RefreshToken
	require.NoError(t, f.db.Where("token_family = ? AND revoked_at IS NULL", f.family).First(&rotated).Error)
	require.WithinDuration(t, *current.AuthenticatedAt, *rotated.AuthenticatedAt, time.Millisecond)
}

func TestReauthenticateRejectsWrongPasswordSubjectAndInvalidSession(t *testing.T) {
	for _, kind := range []string{"wrong_password", "other_subject", "missing_subject", "missing_auth", "missing_family", "revoked", "expired", "unknown_field", "trailing_json"} {
		t.Run(kind, func(t *testing.T) {
			f := newReauthenticationFixture(t, nil)
			token, body, expected := f.token, f.body("synthetic-password"), http.StatusUnauthorized
			switch kind {
			case "wrong_password":
				body, expected = f.body("wrong-password"), http.StatusForbidden
			case "other_subject":
				body, expected = `{"password":"synthetic-password","expected_user_id":`+strconv.Itoa(int(f.user.ID+1))+`}`, http.StatusConflict
			case "missing_subject":
				body, expected = `{"password":"synthetic-password"}`, http.StatusUnprocessableEntity
			case "missing_auth":
				token = ""
			case "missing_family":
				var err error
				token, err = middleware.GenerateToken(f.user.ID, string(f.user.Role), f.user.TokenVersion, f.h.jwtSecret)
				require.NoError(t, err)
			case "revoked":
				require.NoError(t, f.db.Model(&models.RefreshToken{}).Where("token_family = ?", f.family).Update("revoked_at", time.Now()).Error)
			case "expired":
				require.NoError(t, f.db.Model(&models.RefreshToken{}).Where("token_family = ?", f.family).Update("expires_at", time.Now().Add(-time.Minute)).Error)
			case "unknown_field":
				body, expected = `{"password":"synthetic-password","expected_user_id":`+strconv.Itoa(int(f.user.ID))+`,"authenticated_at":"2099-01-01"}`, http.StatusUnprocessableEntity
			case "trailing_json":
				body, expected = body+" garbage", http.StatusUnprocessableEntity
			}
			w := f.send(t, token, body)
			require.Equal(t, expected, w.Code, w.Body.String())
			var stored models.RefreshToken
			require.NoError(t, f.db.Where("token_family = ?", f.family).First(&stored).Error)
			require.WithinDuration(t, f.old, *stored.AuthenticatedAt, time.Millisecond)
		})
	}
}

func TestReauthenticateRateLimitAndAuditFailureDoNotExtendProof(t *testing.T) {
	t.Run("password_throttle", func(t *testing.T) {
		f := newReauthenticationFixture(t, nil)
		for range 2 {
			require.Equal(t, 403, f.send(t, f.token, f.body("wrong-password")).Code)
		}
		w := f.send(t, f.token, f.body("wrong-password"))
		require.Equal(t, 429, w.Code)
		require.NotEmpty(t, w.Header().Get("Retry-After"))
		require.Equal(t, 429, f.send(t, f.token, f.body("synthetic-password")).Code)
	})
	t.Run("audit_rollback", func(t *testing.T) {
		f := newReauthenticationFixture(t, nil)
		require.NoError(t, f.db.Migrator().DropTable(&models.AccountSecurityAuditLog{}))
		w := f.send(t, f.token, f.body("synthetic-password"))
		require.Equal(t, 503, w.Code)
		var stored models.RefreshToken
		require.NoError(t, f.db.Where("token_family = ?", f.family).First(&stored).Error)
		require.WithinDuration(t, f.old, *stored.AuthenticatedAt, time.Millisecond)
	})
}

func TestReauthenticatePostgresDoesNotRestoreConcurrentlyRevokedSession(t *testing.T) {
	f := newReauthenticationFixture(t, integrationLockDB(t))
	tx := f.db.Begin()
	require.NoError(t, tx.Error)
	defer tx.Rollback()
	var user models.User
	require.NoError(t, tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, f.user.ID).Error)
	require.NoError(t, tx.Model(&models.RefreshToken{}).Where("token_family = ?", f.family).Update("revoked_at", time.Now()).Error)
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { done <- f.send(t, f.token, f.body("synthetic-password")) }()
	require.Eventually(t, func() bool {
		var blocked int64
		err := f.db.Raw("SELECT count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND wait_event_type = 'Lock' AND query LIKE '%FROM \"users\"%' AND query LIKE '%FOR UPDATE%'").Scan(&blocked).Error
		return err == nil && blocked > 0
	}, 5*time.Second, 20*time.Millisecond, "应等待同一个用户锁，而不是绕过正在进行的撤销")
	require.NoError(t, tx.Commit().Error)
	select {
	case result := <-done:
		require.Equal(t, http.StatusUnauthorized, result.Code, result.Body.String())
	case <-time.After(5 * time.Second):
		t.Fatal("并发撤销结束后验证请求未能恢复")
	}
	var stored models.RefreshToken
	require.NoError(t, f.db.Where("token_family = ?", f.family).First(&stored).Error)
	require.NotNil(t, stored.RevokedAt)
	require.WithinDuration(t, f.old, *stored.AuthenticatedAt, time.Millisecond)
}
