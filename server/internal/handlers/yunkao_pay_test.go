package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newPayTestHandler(t *testing.T) *YunkaoPayHandler {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(
		&models.YunkaoPayOrder{},
		&models.SystemConfig{},
	); err != nil {
		t.Fatal(err)
	}
	return NewYunkaoPayHandler(db)
}

func TestCreatePayOrderReturnsCheckoutWhenGatewayMissing(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := newPayTestHandler(t)
	router := gin.New()
	router.POST("/api/yunkao/pay/create", func(c *gin.Context) {
		c.Set("user_id", uint(7))
		handler.CreatePayOrder(c)
	})

	req := httptest.NewRequest(
		http.MethodPost,
		"/api/yunkao/pay/create",
		strings.NewReader(`{"amount_cents":1000,"pay_type":"alipay"}`),
	)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var response map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	payURL, _ := response["pay_url"].(string)
	if !strings.Contains(payURL, "/api/yunkao/pay/checkout?order_no=") {
		t.Fatalf("expected checkout URL, got %q", payURL)
	}
}

func TestCheckoutPageShowsMaintenanceWithoutGateway(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := newPayTestHandler(t)
	order := models.YunkaoPayOrder{
		OrderNo:     "YKTEST123",
		UserID:      7,
		AmountCents: 1000,
		Gateway:     "epay",
		PayType:     "alipay",
		Status:      "pending",
	}
	if err := handler.db.Create(&order).Error; err != nil {
		t.Fatal(err)
	}

	router := gin.New()
	router.GET("/api/yunkao/pay/checkout", handler.CheckoutPage)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(
		http.MethodGet,
		"/api/yunkao/pay/checkout?order_no=YKTEST123",
		nil,
	)
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "在线支付通道正在配置中") {
		t.Fatalf("unexpected checkout page: %s", rec.Body.String())
	}
}

func TestRechargeEntryPageCreatesOrderInBrowser(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := newPayTestHandler(t)
	router := gin.New()
	router.GET("/api/yunkao/pay/recharge-page", handler.RechargePage)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/yunkao/pay/recharge-page", nil)
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	body := rec.Body.String()
	for _, expected := range []string{
		`data-cents="500"`,
		`/api/yunkao/pay/create`,
		`location.hash`,
		`Authorization`,
	} {
		if !strings.Contains(body, expected) {
			t.Fatalf("recharge page missing %q", expected)
		}
	}
}
