package handlers

import (
	"context"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func TestIntegrationCancelDeviceHTTPRequiresOnlyOriginalDeviceSecret(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{Logger: logger.Discard})
	require.NoError(t, err)
	pool, _ := db.DB()
	pool.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = pool.Close() })
	require.NoError(t, db.AutoMigrate(&models.IntegrationDeviceRequest{}, &models.IntegrationRateBucket{}))
	h := NewIntegrationHandler(db, IntegrationOptions{})
	router := gin.New()
	h.Register(router, "synthetic-secret")
	device, err := h.auth.RequestDevice(context.Background(), uuid.NewString(), "QQ 123456789 · 合成助手", "profile:read_minimal")
	require.NoError(t, err)
	send := func(contentType, body string) *httptest.ResponseRecorder {
		request := httptest.NewRequest("POST", "/api/oauth/device_authorization/cancel", strings.NewReader(body))
		request.Header.Set("Content-Type", contentType)
		response := httptest.NewRecorder()
		router.ServeHTTP(response, request)
		return response
	}
	for _, form := range []url.Values{
		{"client_id": {"other"}, "device_code": {device.DeviceCode}},
		{"client_id": {services.IntegrationClientID}, "device_code": {device.UserCode}},
		{"client_id": {services.IntegrationClientID}, "device_code": {device.DeviceCode}, "qq": {"987654321"}},
		{"client_id": {services.IntegrationClientID}, "device_code": {device.DeviceCode, device.DeviceCode}},
	} {
		require.Equal(t, 400, send("application/x-www-form-urlencoded", form.Encode()).Code)
	}
	form := url.Values{"client_id": {services.IntegrationClientID}, "device_code": {device.DeviceCode}}
	for range 2 {
		response := send("application/x-www-form-urlencoded", form.Encode())
		require.Equal(t, 200, response.Code, response.Body.String())
		require.Empty(t, response.Body.String())
		require.Equal(t, "no-store", response.Header().Get("Cache-Control"))
	}
	var row models.IntegrationDeviceRequest
	require.NoError(t, db.Where("device_hash = ?", services.IntegrationSecretHash(device.DeviceCode)).Take(&row).Error)
	require.Equal(t, "denied", row.State)
}
