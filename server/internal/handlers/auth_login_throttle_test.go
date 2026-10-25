package handlers

import (
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestLoginThrottleQueryFailurePreservesMemoryLock(t *testing.T) {
	h, db, user, _ := remediationAuthFixture(t)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = sqlDB.Close() })
	testLoginThrottleQueryFailurePreservesMemoryLock(t, h, db, user)
}

func testLoginThrottleQueryFailurePreservesMemoryLock(t *testing.T, h *AuthHandler, db *gorm.DB, user models.User) {
	t.Helper()
	injected := errors.New("injected login throttle read failure")
	userQueries := 0
	require.NoError(t, db.Callback().Query().Before("gorm:query").Register("test:throttle_read_failure", func(tx *gorm.DB) {
		switch tx.Statement.Table {
		case "login_throttle_records":
			tx.AddError(injected)
		case "users":
			userQueries++
		}
	}))
	defer func() { require.NoError(t, db.Callback().Query().Remove("test:throttle_read_failure")) }()
	router := gin.New()
	require.NoError(t, router.SetTrustedProxies(nil))
	router.POST("/api/login", h.Login)

	for _, kind := range []string{"account", "ip"} {
		t.Run(kind, func(t *testing.T) {
			ip := "203.0.113.70"
			value, failures := user.Email, 3
			if kind == "ip" {
				value, failures = ip, 10
			}
			scope := loginThrottleScope(kind, value)
			clearLoginFailures(scope)
			t.Cleanup(func() { clearLoginFailures(scope) })
			now := time.Now()
			for i := 0; i < failures; i++ {
				h.registerLoginFailure(scope, now)
			}
			remaining, locked := currentLoginLock(scope, now)
			require.True(t, locked, "failed database writes must establish the memory lock")
			require.Equal(t, time.Minute, remaining)
			for _, password := range []string{"old-password", "wrong-password"} {
				userQueries = 0
				response := remediationRequest(router, "/api/login", map[string]string{"account": user.Email, "password": password}, ip, "throttle-test")
				require.Equal(t, http.StatusTooManyRequests, response.Code, response.Body.String())
				require.NotEmpty(t, response.Header().Get("Retry-After"))
				require.Zero(t, userQueries, "locked requests must stop before user lookup and bcrypt")
			}
			_, locked = h.loginLock(scope, now.Add(time.Minute))
			require.False(t, locked, "the fallback must respect the lock expiry")
			clearLoginFailures(scope)
		})
	}
	var sessions int64
	require.NoError(t, db.Model(&models.RefreshToken{}).Count(&sessions).Error)
	require.Zero(t, sessions, "a correct password must not create a session during a fallback lock")
}

func TestLoginThrottleDatabaseReadRemainsAuthoritative(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = sqlDB.Close() })
	require.NoError(t, db.AutoMigrate(&models.LoginThrottleRecord{}))
	h := &AuthHandler{db: db}
	scope := loginThrottleScope("account", "authoritative@example.com")
	clearLoginFailures(scope)
	t.Cleanup(func() { clearLoginFailures(scope) })
	now := time.Now()
	for i := 0; i < 3; i++ {
		registerLoginFailure(scope, now)
	}
	_, locked := h.loginLock(scope, now)
	require.False(t, locked, "a successful database not-found result must not revive stale memory locks")
	record := models.LoginThrottleRecord{Scope: scope, FailureCount: 1, LastFailureAt: &now}
	require.NoError(t, db.Create(&record).Error)
	_, locked = h.loginLock(scope, now)
	require.False(t, locked, "a readable unlocked database row remains authoritative")
	until := now.Add(20 * time.Second)
	require.NoError(t, db.Model(&record).Update("locked_until", until).Error)
	remaining, locked := h.loginLock(scope, now)
	require.True(t, locked)
	require.Equal(t, 20*time.Second, remaining, "the shared database deadline takes precedence")
}

func TestLoginLockDurationForFailures(t *testing.T) {
	cases := []struct {
		failures int
		want     time.Duration
	}{
		{1, 0},
		{2, 0},
		{3, time.Minute},
		{4, 3 * time.Minute},
		{5, 5 * time.Minute},
		{6, 10 * time.Minute},
		{9, 10 * time.Minute},
	}

	for _, tc := range cases {
		if got := loginLockDurationForFailures(tc.failures); got != tc.want {
			t.Fatalf("failures=%d got=%v want=%v", tc.failures, got, tc.want)
		}
	}
}

func TestLoginThrottleEscalatesAndClears(t *testing.T) {
	account := "test-account"
	clearLoginFailures(account)
	base := time.Date(2026, 5, 6, 12, 0, 0, 0, time.UTC)

	if got := registerLoginFailure(account, base); got != 0 {
		t.Fatalf("first failure should not lock, got %v", got)
	}
	if got := registerLoginFailure(account, base); got != 0 {
		t.Fatalf("second failure should not lock, got %v", got)
	}
	if got := registerLoginFailure(account, base); got != time.Minute {
		t.Fatalf("third failure got %v want %v", got, time.Minute)
	}
	if remaining, locked := currentLoginLock(account, base.Add(30*time.Second)); !locked || remaining <= 0 {
		t.Fatalf("expected account to be locked after third failure")
	}
	if remaining, locked := currentLoginLock(account, base.Add(time.Minute)); locked || remaining != 0 {
		t.Fatalf("expected lock to expire at boundary, got locked=%v remaining=%v", locked, remaining)
	}
	if got := registerLoginFailure(account, base.Add(time.Minute)); got != 3*time.Minute {
		t.Fatalf("lock expiry should retain the failure window, got %v", got)
	}
	if got := registerLoginFailure(account, base.Add(16*time.Minute)); got != 0 {
		t.Fatalf("failure window expiry should reset the counter, got %v", got)
	}

	clearLoginFailures(account)
	if remaining, locked := currentLoginLock(account, base.Add(2*time.Minute)); locked || remaining != 0 {
		t.Fatalf("expected account to be cleared after success/reset")
	}
}

func TestLoginThrottleRetainsSourceCountAcrossExpiredLocks(t *testing.T) {
	source := loginThrottleScope("ip", "203.0.113.21")
	clearLoginFailures(source)
	base := time.Date(2026, 5, 6, 12, 0, 0, 0, time.UTC)

	for i := 1; i <= 10; i++ {
		if got := registerLoginFailure(source, base); (i < 10 && got != 0) || (i == 10 && got != time.Minute) {
			t.Fatalf("source failure %d lock=%v", i, got)
		}
	}
	if _, locked := currentLoginLock(source, base.Add(time.Minute+time.Second)); locked {
		t.Fatal("source lock should expire before the failure window")
	}
	next := base.Add(time.Minute + time.Second)
	for i := 11; i <= 19; i++ {
		if got := registerLoginFailure(source, next); got != time.Minute {
			t.Fatalf("source failure %d should retain the short lock while accumulating, got %v", i, got)
		}
		next = next.Add(time.Minute + time.Second)
	}
	if got := registerLoginFailure(source, next); got != 5*time.Minute {
		t.Fatalf("source failure 20 should escalate to five minutes, got %v", got)
	}
	clearLoginFailures(source)
}

func TestDatabaseLoginThrottleRetainsSourceCountAcrossExpiredLocks(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.LoginThrottleRecord{}); err != nil {
		t.Fatalf("迁移登录限流表失败: %v", err)
	}
	h := &AuthHandler{db: db}
	source := loginThrottleScope("ip", "203.0.113.22")
	base := time.Date(2026, 5, 6, 12, 0, 0, 0, time.UTC)

	for i := 1; i <= 10; i++ {
		if got := h.registerLoginFailure(source, base); (i < 10 && got != 0) || (i == 10 && got != time.Minute) {
			t.Fatalf("数据库来源失败 %d 锁定=%v", i, got)
		}
	}
	if _, locked := h.loginLock(source, base.Add(time.Minute+time.Second)); locked {
		t.Fatal("数据库来源锁定窗口应已结束")
	}
	next := base.Add(time.Minute + time.Second)
	for i := 11; i <= 19; i++ {
		if got := h.registerLoginFailure(source, next); got != time.Minute {
			t.Fatalf("数据库来源失败 %d 应继续累计并短暂锁定，得到 %v", i, got)
		}
		next = next.Add(time.Minute + time.Second)
	}
	if got := h.registerLoginFailure(source, next); got != 5*time.Minute {
		t.Fatalf("数据库来源失败 20 应升级到五分钟，得到 %v", got)
	}
}

func TestLoginSourceThrottleDoesNotLockAfterThreeFailures(t *testing.T) {
	source := loginThrottleScope("ip", "203.0.113.20")
	clearLoginFailures(source)
	base := time.Date(2026, 5, 6, 12, 0, 0, 0, time.UTC)
	for i := 1; i <= 9; i++ {
		if got := registerLoginFailure(source, base); got != 0 {
			t.Fatalf("共享来源第 %d 次失败不应锁定，得到 %v", i, got)
		}
	}
	if got := registerLoginFailure(source, base); got != time.Minute {
		t.Fatalf("共享来源第 10 次失败应进入短暂保护，得到 %v", got)
	}
	clearLoginFailures(source)
}
