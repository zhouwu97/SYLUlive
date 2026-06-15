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
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newVipTestHandler(t *testing.T) *VipHandler {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.User{}); err != nil {
		t.Fatal(err)
	}
	return NewVipHandler(db, "", "")
}

func TestPushUpdateToVipDryRunCountsActiveVipDevices(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := newVipTestHandler(t)
	now := time.Now()
	activeExpiry := now.Add(24 * time.Hour)
	expired := now.Add(-24 * time.Hour)
	users := []models.User{
		{StudentID: "vip-with-token", PasswordHash: "x", DeviceToken: "rid-1", VipExpiry: &activeExpiry},
		{StudentID: "vip-no-token", PasswordHash: "x", VipExpiry: &activeExpiry},
		{StudentID: "expired-vip", PasswordHash: "x", DeviceToken: "rid-2", VipExpiry: &expired},
	}
	if err := handler.db.Create(&users).Error; err != nil {
		t.Fatal(err)
	}

	body := map[string]any{
		"download_url": "https://example.com/app.apk",
		"dry_run":      true,
	}
	payload, _ := json.Marshal(body)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodPost, "/api/super/vip/push_update", bytes.NewReader(payload))
	context.Request.Header.Set("Content-Type", "application/json")

	handler.PushUpdateToVip(context)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", recorder.Code, recorder.Body.String())
	}
	var response map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response["target_count"].(float64) != 1 {
		t.Fatalf("expected one active VIP device, got %#v", response)
	}
	if response["dry_run"] != true || response["sent"].(float64) != 0 {
		t.Fatalf("expected dry run without sends, got %#v", response)
	}
}

func TestPushUpdateToVipRejectsInvalidDownloadURL(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := newVipTestHandler(t)

	body := map[string]any{
		"download_url": "javascript:alert(1)",
		"dry_run":      true,
	}
	payload, _ := json.Marshal(body)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodPost, "/api/super/vip/push_update", bytes.NewReader(payload))
	context.Request.Header.Set("Content-Type", "application/json")

	handler.PushUpdateToVip(context)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d body=%s", recorder.Code, recorder.Body.String())
	}
}
