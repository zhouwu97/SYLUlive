package handlers

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

func newOneClassPayTestHandler(t *testing.T) *OneClassPayHandler {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.OneClassPayOrder{}, &models.User{}); err != nil {
		t.Fatal(err)
	}
	return NewOneClassPayHandler(db)
}

func TestOneClassPayStatusLazyIssuesLicenseToken(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := newOneClassPayTestHandler(t)
	paidAt := time.Date(2026, 6, 15, 8, 0, 0, 0, time.UTC)
	order := models.OneClassPayOrder{
		UserID:      1,
		OrderNo:     "OCLAZY123",
		Tier:        models.OneClassTierOneTime,
		Title:       "OneClass 一次性购买",
		MachineID:   "oc-test-machine",
		AmountCents: 300,
		PayType:     "alipay",
		Status:      "completed",
		PaidAt:      &paidAt,
	}
	if err := handler.db.Create(&order).Error; err != nil {
		t.Fatal(err)
	}

	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/oneclass/pay/status?order_no=OCLAZY123", nil)
	context.Request.Header.Set("X-OneClass-Client", "desktop")

	handler.PayStatus(context)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", recorder.Code, recorder.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	token, _ := body["license_token"].(string)
	if token == "" || len(strings.Split(token, ".")) != 3 {
		t.Fatalf("expected JWT license token, got %q", token)
	}

	var stored models.OneClassPayOrder
	if err := handler.db.Where("order_no = ?", "OCLAZY123").First(&stored).Error; err != nil {
		t.Fatal(err)
	}
	if stored.LicenseToken == "" || stored.LicenseIssuedAt == nil || stored.UpdatesUntil == nil {
		t.Fatalf("expected lazy-issued token fields, got %#v", stored)
	}
}

func TestOneClassPayStatusDoesNotExposeLicenseToBrowser(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := newOneClassPayTestHandler(t)
	paidAt := time.Date(2026, 6, 15, 8, 0, 0, 0, time.UTC)
	order := models.OneClassPayOrder{
		UserID:      1,
		OrderNo:     "OCBROWSER123",
		Tier:        models.OneClassTierOneTime,
		Title:       "OneClass 一次性购买",
		MachineID:   "oc-test-machine",
		AmountCents: 300,
		PayType:     "alipay",
		Status:      "completed",
		PaidAt:      &paidAt,
	}
	if err := handler.db.Create(&order).Error; err != nil {
		t.Fatal(err)
	}

	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/oneclass/pay/status?order_no=OCBROWSER123", nil)

	handler.PayStatus(context)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", recorder.Code, recorder.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if _, exists := body["license_token"]; exists {
		t.Fatalf("browser status response must not expose license_token: %#v", body)
	}

	var stored models.OneClassPayOrder
	if err := handler.db.Where("order_no = ?", "OCBROWSER123").First(&stored).Error; err != nil {
		t.Fatal(err)
	}
	if stored.LicenseToken != "" || stored.LicenseIssuedAt != nil {
		t.Fatalf("browser status must not lazy issue token, got %#v", stored)
	}
}

func TestOneClassLicenseKeyRequiredInGinReleaseMode(t *testing.T) {
	t.Setenv("GIN_MODE", "release")
	t.Setenv("ONECLASS_LICENSE_PRIVATE_KEY", "")

	if _, err := oneClassLicensePrivateKey(); err == nil {
		t.Fatal("expected release mode to require ONECLASS_LICENSE_PRIVATE_KEY")
	}
}
