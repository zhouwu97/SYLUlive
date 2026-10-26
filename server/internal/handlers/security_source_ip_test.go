package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

type testOfflineLocator struct{}

func (testOfflineLocator) Lookup(ip string) services.SecurityIPLocation {
	return services.SecurityIPLocation{Region: "中国 · 辽宁省 · 沈阳市", Status: "resolved"}
}
func (testOfflineLocator) State() (string, string) { return "ready", "offline" }

func TestSecuritySourceIPAdminDTOAndHistoricalFallback(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.SecurityEvent{}))
	service := services.NewSecurityEventService(db, "test-secret", nil)
	require.NoError(t, service.Record(services.SecurityEventInput{EventType: "login_bruteforce", ClientIP: "1.2.3.4"}))
	var event models.SecurityEvent
	require.NoError(t, db.First(&event).Error)
	h := NewSecurityAdminHandler(db, service)
	h.SetIPLocator(testOfflineLocator{})
	normal := h.securityEventDTO(event, false)
	require.Equal(t, "1.2.3.4", normal.SourceIP)
	require.Equal(t, "中国 · 辽宁省 · 沈阳市", normal.SourceRegion)
	require.Empty(t, normal.SourceKey)
	super := h.securityEventDTO(event, true)
	require.Equal(t, event.SourceIPHash, super.SourceKey)
	encoded, err := json.Marshal(normal)
	require.NoError(t, err)
	require.NotContains(t, string(encoded), event.SourceIPCiphertext)
	// 使用与生产路由相同的角色门禁，普通用户不能取得任何预警 IP。
	for _, role := range []string{"user", "admin", "super_admin"} {
		router := gin.New()
		router.Use(func(c *gin.Context) { c.Set("role", role); c.Next() }, middleware.AdminMiddleware())
		router.GET("/events", h.ListEvents)
		r := httptest.NewRecorder()
		router.ServeHTTP(r, httptest.NewRequest(http.MethodGet, "/events", nil))
		if role == "user" {
			require.Equal(t, http.StatusForbidden, r.Code)
			require.NotContains(t, r.Body.String(), "1.2.3.4")
		} else {
			require.Equal(t, http.StatusOK, r.Code)
			require.Contains(t, r.Body.String(), `"source_ip":"1.2.3.4"`)
		}
	}
	h.SetProtectionConfig(false, nil, time.Now().Add(time.Hour).Format(time.RFC3339))
	untrusted := h.securityEventDTO(event, true)
	require.Empty(t, untrusted.SourceIP)
	require.Equal(t, "untrusted", untrusted.SourceIPStatus)
	h.SetProtectionConfig(false, nil, "")
	event.SourceIPCiphertext = ""
	historical := h.securityEventDTO(event, true)
	require.Empty(t, historical.SourceIP)
	require.Equal(t, "not_recorded", historical.SourceIPStatus)
}

func TestSecurityEventsPageOverflowRejectedAndRequestCancellationHonored(t *testing.T) {
	h, _ := newSecurityOverviewTestHandler(t)
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.GET("/events", h.ListEvents)
	r := httptest.NewRecorder()
	router.ServeHTTP(r, httptest.NewRequest(http.MethodGet, "/events?page=9223372036854775807", nil))
	require.Equal(t, http.StatusBadRequest, r.Code)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r = httptest.NewRecorder()
	router.ServeHTTP(r, httptest.NewRequest(http.MethodGet, "/events", nil).WithContext(ctx))
	require.Equal(t, http.StatusInternalServerError, r.Code)
}
