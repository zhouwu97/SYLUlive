package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func newSecurityTargetAccountHandler(t *testing.T) (*SecurityAdminHandler, *gorm.DB) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	t.Cleanup(func() { _ = sqlDB.Close() })
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.SecurityEvent{}))
	service := services.NewSecurityEventService(db, "target-account-test-secret", nil)
	return NewSecurityAdminHandler(db, service), db
}

func TestSecurityTargetAccountAdminListAndDetail(t *testing.T) {
	h, db := newSecurityTargetAccountHandler(t)
	const email = "3212345678@qq.com"
	for _, candidate := range []string{email, "3299999999@qq.com"} {
		require.NoError(t, db.Create(&models.User{Email: candidate, PasswordHash: "fixture"}).Error)
	}
	require.NoError(t, h.security.Record(services.SecurityEventInput{
		EventType: "login_bruteforce", TargetType: "account", TargetValue: email,
		TargetMasked: maskLoginSecurityTarget(email), ClientIP: "203.0.113.8", Blocked: true,
	}))
	var event models.SecurityEvent
	require.NoError(t, db.First(&event).Error)
	stored, err := json.Marshal(event)
	require.NoError(t, err)
	require.NotContains(t, string(stored), email)
	require.NotContains(t, string(stored), event.TargetAccountCiphertext)
	// 同一摘要的普通审计不能因同页存在登录预警而取得完整邮箱。
	audit := event
	audit.ID = 0
	audit.BucketKey = "audit"
	audit.EventType = "login_failed"
	require.NoError(t, db.Create(&audit).Error)

	for _, role := range []string{"user", "admin", "super_admin"} {
		for _, path := range []string{"/events", "/events/1"} {
			t.Run(role+path, func(t *testing.T) {
				router := gin.New()
				router.Use(func(c *gin.Context) { c.Set("role", role); c.Next() }, middleware.AdminMiddleware())
				router.GET("/events", h.ListEvents)
				router.GET("/events/:id", h.GetEvent)
				response := httptest.NewRecorder()
				router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
				if role == "user" {
					require.Equal(t, http.StatusForbidden, response.Code)
					require.NotContains(t, response.Body.String(), email)
					return
				}
				require.Equal(t, http.StatusOK, response.Code)
				require.Contains(t, response.Body.String(), `"target_account":"`+email+`"`)
				require.Contains(t, response.Body.String(), `"target_account_status":"available"`)
				require.Contains(t, response.Body.String(), `"target_masked":"32***@qq.com"`)
				require.NotContains(t, response.Body.String(), "3299999999@qq.com")
				require.Equal(t, 1, strings.Count(response.Body.String(), `"target_account"`))
			})
		}
	}
}

func TestSecurityTargetAccountUnknownTargetDoesNotRequireUserDirectory(t *testing.T) {
	h, db := newSecurityTargetAccountHandler(t)
	const target = "unregistered@example.invalid"
	require.NoError(t, h.security.Record(services.SecurityEventInput{EventType: "login_bruteforce", TargetType: "account",
		TargetValue: target, TargetMasked: "un***@example.invalid"}))
	require.NoError(t, db.Migrator().DropTable(&models.User{}))
	router := gin.New()
	router.GET("/events", h.ListEvents)
	router.GET("/events/:id", h.GetEvent)
	for _, path := range []string{"/events", "/events/1"} {
		response := httptest.NewRecorder()
		router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
		require.Equal(t, http.StatusOK, response.Code)
		require.Contains(t, response.Body.String(), `"target_account":"`+target+`"`)
	}
	// 密文有误时明确报告不可读取，不能用当前邮箱反查掩盖密文故障。
	require.NoError(t, db.Model(&models.SecurityEvent{}).Where("id = 1").Update("target_account_ciphertext", "corrupt").Error)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/events/1", nil))
	require.Equal(t, http.StatusOK, response.Code)
	require.Contains(t, response.Body.String(), `"target_account_status":"unavailable"`)
	require.NotContains(t, response.Body.String(), target)
}

func TestSecurityTargetAccountRequiresExactHashAndCurrentAccount(t *testing.T) {
	h, db := newSecurityTargetAccountHandler(t)
	const email = "3212345678@qq.com"
	user := models.User{Email: email, PasswordHash: "fixture"}
	require.NoError(t, db.Create(&user).Error)
	event := models.SecurityEvent{
		ID: 1, EventType: "login_bruteforce", TargetType: "account",
		TargetMasked: maskLoginSecurityTarget(email), TargetHash: h.security.Hash(email),
	}
	accounts, err := h.securityTargetAccounts(context.Background(), []models.SecurityEvent{event})
	require.NoError(t, err)
	require.Equal(t, email, accounts[event.ID])
	for _, change := range []func(*models.SecurityEvent){
		func(e *models.SecurityEvent) { e.TargetHash = h.security.Hash("3299999999@qq.com") },
		func(e *models.SecurityEvent) { e.TargetHash = "" },
		func(e *models.SecurityEvent) {
			e.TargetHash = services.NewSecurityEventService(db, "rotated", nil).Hash(email)
		},
		func(e *models.SecurityEvent) { e.TargetType = "route" },
		func(e *models.SecurityEvent) { e.EventType = "login_failed" },
		func(e *models.SecurityEvent) { e.TargetMasked = "***@qq.com" },
		func(e *models.SecurityEvent) { e.TargetMasked = "32***@other.example" },
	} {
		candidate := event
		change(&candidate)
		accounts, err := h.securityTargetAccounts(context.Background(), []models.SecurityEvent{candidate})
		require.NoError(t, err)
		require.Empty(t, accounts)
	}
	for _, update := range []map[string]interface{}{
		{"email": "new@example.com"},
		{"email": email, "account_status": "cancelled"},
	} {
		require.NoError(t, db.Model(&user).Updates(update).Error)
		accounts, err := h.securityTargetAccounts(context.Background(), []models.SecurityEvent{event})
		require.NoError(t, err)
		require.Empty(t, accounts)
	}
}

func TestSecurityTargetAccountEscapedEmailsAndLookupFailure(t *testing.T) {
	h, db := newSecurityTargetAccountHandler(t)
	var events []models.SecurityEvent
	for i, email := range []string{"a%test@example.com", "a_test@example.com", "a!test@example.com", "a@qq.com"} {
		require.NoError(t, db.Create(&models.User{Email: email, PasswordHash: "fixture"}).Error)
		events = append(events, models.SecurityEvent{ID: uint(i + 1), EventType: "login_bruteforce", TargetType: "account",
			TargetMasked: maskLoginSecurityTarget(email), TargetHash: h.security.Hash(email)})
	}
	accounts, err := h.securityTargetAccounts(context.Background(), events)
	require.NoError(t, err)
	require.Len(t, accounts, 4)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = h.securityTargetAccounts(ctx, events)
	require.ErrorIs(t, err, context.Canceled)

	require.NoError(t, db.Migrator().DropTable(&models.User{}))
	_, err = h.securityTargetAccounts(context.Background(), events)
	require.Error(t, err)
}
