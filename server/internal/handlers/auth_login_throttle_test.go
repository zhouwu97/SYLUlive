package handlers

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
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
			value, failures := user.Email, loginAccountFailureLimit
			if kind == "ip" {
				value, failures = ip, loginSourceFailureLimit
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
			require.Equal(t, 24*time.Hour, remaining)
			for _, password := range []string{"old-password", "wrong-password"} {
				userQueries = 0
				response := remediationRequest(router, "/api/login", map[string]string{"account": user.Email, "password": password}, ip, "throttle-test")
				require.Equal(t, http.StatusTooManyRequests, response.Code, response.Body.String())
				require.NotEmpty(t, response.Header().Get("Retry-After"))
				require.Zero(t, userQueries, "locked requests must stop before user lookup and bcrypt")
			}
			_, locked = h.loginLock(scope, now.Add(24*time.Hour))
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
	for i := 0; i < loginAccountFailureLimit; i++ {
		registerLoginFailure(scope, now)
	}
	_, locked := h.loginLock(scope, now)
	require.False(t, locked, "a successful database not-found result must not revive stale memory locks")
	record := models.LoginThrottleRecord{Scope: scope, FailureCount: 1, LastFailureAt: &now}
	require.NoError(t, db.Create(&record).Error)
	_, locked = h.loginLock(scope, now)
	require.False(t, locked, "a readable unlocked database row remains authoritative")
	until := now.Add(20 * time.Second)
	require.NoError(t, db.Model(&record).Updates(map[string]interface{}{"failure_count": loginAccountFailureLimit, "locked_until": until}).Error)
	remaining, locked := h.loginLock(scope, now)
	require.True(t, locked)
	require.Equal(t, 20*time.Second, remaining, "the shared database deadline takes precedence")
}

func TestDatabaseLoginThrottleReadCannotEraseConcurrentFailure(t *testing.T) {
	for _, expiredWindow := range []bool{false, true} {
		t.Run(map[bool]string{false: "expired_lock", true: "expired_failure_window"}[expiredWindow], func(t *testing.T) {
			db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
			require.NoError(t, err)
			require.NoError(t, db.AutoMigrate(&models.LoginThrottleRecord{}))
			now := time.Now()
			lastFailure, oldLock := now.Add(-2*time.Minute), now.Add(-time.Minute)
			if expiredWindow {
				lastFailure = now.Add(-16 * time.Minute)
			}
			record := models.LoginThrottleRecord{Scope: loginThrottleScope("account", t.Name()), FailureCount: loginAccountFailureLimit, LastFailureAt: &lastFailure, LockedUntil: &oldLock}
			require.NoError(t, db.Create(&record).Error)
			newLock := now.Add(3 * time.Minute)
			// 读操作已取得过期快照时，另一个请求完成新的失败计数。
			require.NoError(t, db.Callback().Query().After("gorm:query").Register("test:concurrent-failure", func(tx *gorm.DB) {
				if tx.Statement.Table == "login_throttle_records" {
					require.NoError(t, db.Model(&models.LoginThrottleRecord{}).Where("id = ?", record.ID).Updates(map[string]interface{}{
						"failure_count": loginAccountFailureLimit + 1, "last_failure_at": now, "locked_until": newLock,
					}).Error)
				}
			}))
			h := &AuthHandler{db: db}
			h.loginLock(record.Scope, now)
			require.NoError(t, db.Callback().Query().Remove("test:concurrent-failure"))
			var stored models.LoginThrottleRecord
			require.NoError(t, db.First(&stored, record.ID).Error)
			require.NotNil(t, stored.LockedUntil)
			require.WithinDuration(t, newLock, *stored.LockedUntil, time.Millisecond)
		})
	}
}

func TestLoginLockDurationForFailures(t *testing.T) {
	for _, count := range []int{0, 1, 2, 3, 6, 10, 99} {
		require.Zero(t, loginLockDurationForFailures(count), "failure %d must remain retryable", count)
	}
	for _, count := range []int{100, 101, 300, 1000} {
		require.Equal(t, 24*time.Hour, loginLockDurationForFailures(count))
	}
	for _, count := range []int{3, 10, 40, 100, 299} {
		require.Zero(t, loginSourceLockDurationForFailures(count), "shared source failure %d", count)
	}
	for _, count := range []int{300, 301, 1000} {
		require.Equal(t, 24*time.Hour, loginSourceLockDurationForFailures(count))
	}
	require.Zero(t, loginLockDurationForScope("reauth:fixture", 2))
	require.Equal(t, time.Minute, loginLockDurationForScope("reauth:fixture", 3))
	require.Equal(t, 10*time.Minute, loginLockDurationForScope("reauth:fixture", 6))
}

func TestLoginThrottleDayCooldownSurvivesFailureWindow(t *testing.T) {
	for _, storage := range []string{"memory", "database"} {
		for _, policy := range []struct {
			kind  string
			limit int
		}{{"account", 100}, {"ip", 300}} {
			t.Run(storage+"_"+policy.kind, func(t *testing.T) {
				h := &AuthHandler{}
				if storage == "database" {
					db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
					require.NoError(t, err)
					require.NoError(t, db.AutoMigrate(&models.LoginThrottleRecord{}))
					sqlDB, err := db.DB()
					require.NoError(t, err)
					t.Cleanup(func() { _ = sqlDB.Close() })
					h.db = db
				}
				scope := loginThrottleScope(policy.kind, t.Name())
				clearLoginFailures(scope)
				t.Cleanup(func() { clearLoginFailures(scope) })
				base := time.Date(2026, 11, 16, 2, 0, 0, 0, time.UTC)
				for i := 1; i < policy.limit; i++ {
					require.Zero(t, h.registerLoginFailure(scope, base), "failure %d", i)
				}
				require.Equal(t, 24*time.Hour, h.registerLoginFailure(scope, base))
				_, locked := h.loginLock(scope, base.Add(16*time.Minute))
				require.True(t, locked, "15-minute inactivity must not clear an active day-long cooldown")
				require.Equal(t, 23*time.Hour, h.registerLoginFailure(scope, base.Add(time.Hour)), "repeated failures cannot extend the original deadline")
				remaining, locked := h.loginLock(scope, base.Add(24*time.Hour-time.Second))
				require.True(t, locked)
				require.Equal(t, time.Second, remaining)
				_, locked = h.loginLock(scope, base.Add(24*time.Hour))
				require.False(t, locked)
				require.Zero(t, h.registerLoginFailure(scope, base.Add(24*time.Hour)), "expired cooldown starts a fresh failure count")
			})
		}
	}
}

func TestLoginCooldownMessageAndRetryBoundary(t *testing.T) {
	require.Equal(t, "1天", formatRetryAfterCN(24*time.Hour))
	require.Equal(t, "23小时", formatRetryAfterCN(23*time.Hour))
	response := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(response)
	writeLoginCooldown(c, time.Millisecond)
	require.Equal(t, "1", response.Header().Get("Retry-After"))
	require.Contains(t, response.Body.String(), "LOGIN_COOLDOWN")
	require.Contains(t, response.Body.String(), "向开发者申诉")
}

func TestLoginThrottleOldLocksRespectRelaxedPolicyWithoutRewriting(t *testing.T) {
	for _, storage := range []string{"memory", "database"} {
		for _, policy := range []struct {
			kind     string
			failures int
			locked   bool
		}{{"account", 3, false}, {"account", 99, false}, {"ip", 10, false}, {"ip", 299, false}, {"account", 100, true}, {"ip", 300, true}} {
			t.Run(storage+"_"+policy.kind+"_"+strconv.Itoa(policy.failures), func(t *testing.T) {
				base := time.Date(2026, 11, 16, 2, 0, 0, 0, time.UTC)
				oldUntil := base.Add(10 * time.Minute)
				scope := loginThrottleScope(policy.kind, t.Name())
				h := &AuthHandler{}
				if storage == "database" {
					db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
					require.NoError(t, err)
					require.NoError(t, db.AutoMigrate(&models.LoginThrottleRecord{}))
					sqlDB, err := db.DB()
					require.NoError(t, err)
					t.Cleanup(func() { _ = sqlDB.Close() })
					require.NoError(t, db.Create(&models.LoginThrottleRecord{Scope: scope, FailureCount: policy.failures, LastFailureAt: &base, LockedUntil: &oldUntil}).Error)
					h.db = db
				} else {
					loginThrottleStore.Lock()
					loginThrottleStore.records[scope] = loginThrottleRecord{FailureCount: policy.failures, LastFailureAt: base, LockedUntil: oldUntil}
					loginThrottleStore.Unlock()
					t.Cleanup(func() { clearLoginFailures(scope) })
				}
				remaining, locked := h.loginLock(scope, base.Add(10*time.Second))
				require.Equal(t, policy.locked, locked)
				if locked {
					require.Equal(t, 10*time.Minute-10*time.Second, remaining)
				}
				_, locked = h.loginLock(scope, base.Add(10*time.Minute))
				require.False(t, locked, "upgrading must not extend existing shorter locks")
				if h.db != nil {
					var stored models.LoginThrottleRecord
					require.NoError(t, h.db.Where("scope = ?", scope).First(&stored).Error)
					require.Equal(t, policy.failures, stored.FailureCount)
					require.WithinDuration(t, oldUntil, *stored.LockedUntil, time.Millisecond, "lock reads must not overwrite concurrent state")
				}
			})
		}
	}
}

func TestLoginCorrectPasswordAfterThreeMistakesSucceeds(t *testing.T) {
	h, db, user, _ := remediationAuthFixture(t)
	router := gin.New()
	require.NoError(t, router.SetTrustedProxies(nil))
	router.POST("/api/login", h.Login)
	for range 3 {
		response := remediationRequest(router, "/api/login", map[string]string{"account": user.Email, "password": "wrong-password"}, "203.0.113.75", "synthetic-device")
		require.Equal(t, http.StatusUnauthorized, response.Code)
	}
	response := remediationRequest(router, "/api/login", map[string]string{"account": user.Email, "password": "old-password"}, "203.0.113.75", "synthetic-device")
	require.Equal(t, http.StatusOK, response.Code, response.Body.String())
	var sessions int64
	require.NoError(t, db.Model(&models.RefreshToken{}).Where("user_id = ?", user.ID).Count(&sessions).Error)
	require.EqualValues(t, 1, sessions)
}

func TestLoginAllowsPasswordCorrectionAndRecoversAfterDayCooldown(t *testing.T) {
	h, db, user, _ := remediationAuthFixture(t)
	router := gin.New()
	require.NoError(t, router.SetTrustedProxies(nil))
	router.POST("/api/login", h.Login)
	wrong := map[string]string{"account": user.Email, "password": "wrong-password"}
	correct := map[string]string{"account": user.Email, "password": "old-password"}
	for i := 1; i <= 99; i++ {
		response := remediationRequest(router, "/api/login", wrong, "203.0.113.74", "synthetic-device")
		require.Equal(t, http.StatusUnauthorized, response.Code, "failure %d: %s", i, response.Body.String())
		require.Empty(t, response.Header().Get("Retry-After"))
	}
	var actionable int64
	require.NoError(t, db.Model(&models.SecurityEvent{}).Where("event_type = ?", "login_bruteforce").Count(&actionable).Error)
	require.Zero(t, actionable, "ordinary password correction must not create a brute-force warning")
	response := remediationRequest(router, "/api/login", wrong, "203.0.113.74", "synthetic-device")
	require.Equal(t, http.StatusTooManyRequests, response.Code)
	require.Equal(t, "86400", response.Header().Get("Retry-After"))
	require.Contains(t, response.Body.String(), "1天")
	require.Contains(t, response.Body.String(), "向开发者申诉")
	response = remediationRequest(router, "/api/login", correct, "203.0.113.74", "synthetic-device")
	require.Equal(t, http.StatusTooManyRequests, response.Code)
	// 使用隔离数据库推进冷却时间，避免真实等待。
	scope := loginThrottleScope("account", user.Email)
	require.NoError(t, db.Model(&models.LoginThrottleRecord{}).Where("scope = ?", scope).Updates(map[string]interface{}{
		"last_failure_at": time.Now().Add(-24*time.Hour - time.Second), "locked_until": time.Now().Add(-time.Second),
	}).Error)
	response = remediationRequest(router, "/api/login", correct, "203.0.113.74", "synthetic-device")
	require.Equal(t, http.StatusOK, response.Code, response.Body.String())
	var count int64
	require.NoError(t, db.Model(&models.LoginThrottleRecord{}).Where("scope = ?", scope).Count(&count).Error)
	require.Zero(t, count, "successful login clears this account's failure count")
	response = remediationRequest(router, "/api/login", wrong, "203.0.113.74", "synthetic-device")
	require.Equal(t, http.StatusUnauthorized, response.Code)
}
