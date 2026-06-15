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

func TestEpayMAPIIsUsedAndResponseIsCached(t *testing.T) {
	gin.SetMode(gin.TestMode)
	callCount := 0
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		if r.URL.Path != "/mapi.php" {
			t.Fatalf("expected /mapi.php, got %s", r.URL.Path)
		}
		if err := r.ParseForm(); err != nil {
			t.Fatal(err)
		}
		for _, key := range []string{"pid", "type", "out_trade_no", "notify_url", "return_url", "name", "money", "sign", "sign_type"} {
			if r.Form.Get(key) == "" {
				t.Fatalf("missing MAPI field %s", key)
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"code":1,"msg":"success","trade_no":"T123","payurl":"https://pay.example/order","qrcode":"https://qr.example/native","urlscheme":"alipays://platformapi/startapp?appId=1"}`))
	}))
	defer gateway.Close()

	handler := newPayTestHandler(t)
	for key, value := range map[string]string{
		models.YunkaoPayEnabled:    "true",
		models.YunkaoPayAppID:      "1105",
		models.YunkaoPayAppSecret:  "secret",
		models.YunkaoPayApiURL:     gateway.URL + "/submit.php",
		models.YunkaoPayNotifyBase: "https://service.example",
	} {
		if err := handler.db.Create(&models.SystemConfig{ConfigKey: key, ConfigValue: value}).Error; err != nil {
			t.Fatal(err)
		}
	}
	order := models.YunkaoPayOrder{
		OrderNo: "YKMAPI123", UserID: 7, AmountCents: 100,
		Gateway: "epay", PayType: "alipay", Status: "pending",
	}
	if err := handler.db.Create(&order).Error; err != nil {
		t.Fatal(err)
	}
	context, _ := gin.CreateTestContext(httptest.NewRecorder())
	context.Request = httptest.NewRequest(http.MethodGet, "/", nil)

	first, err := handler.buildGatewayPayment(context, order)
	if err != nil {
		t.Fatal(err)
	}
	if first.QRCode != "https://qr.example/native" || first.URLScheme == "" {
		t.Fatalf("unexpected payment response: %#v", first)
	}
	if err := handler.db.First(&order, order.ID).Error; err != nil {
		t.Fatal(err)
	}
	second, err := handler.buildGatewayPayment(context, order)
	if err != nil {
		t.Fatal(err)
	}
	if second.QRCode != first.QRCode || callCount != 1 {
		t.Fatalf("expected cached MAPI response, calls=%d response=%#v", callCount, second)
	}
}

func TestEpayMAPIURL(t *testing.T) {
	for input, expected := range map[string]string{
		"https://pay.example":            "https://pay.example/mapi.php",
		"https://pay.example/":           "https://pay.example/mapi.php",
		"https://pay.example/submit.php": "https://pay.example/mapi.php",
		"https://pay.example/mapi.php":   "https://pay.example/mapi.php",
	} {
		actual := epayMAPIURL(input)
		if actual != expected {
			t.Fatalf("epayMAPIURL(%q) = %q, want %q", input, actual, expected)
		}
	}
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
	if !strings.Contains(rec.Body.String(), "请务必核对付款金额") ||
		!strings.Contains(rec.Body.String(), "金额错误概不退款") {
		t.Fatalf("checkout page missing payment warning: %s", rec.Body.String())
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
		`data-cents="100"`,
		`data-cents="300"`,
		`data-cents="500"`,
		`data-cents="1000"`,
		`/api/yunkao/pay/create`,
		`location.hash`,
		`Authorization`,
		`id="custom"`,
		`请务必仔细核对充值金额`,
		`金额填写错误概不退款`,
	} {
		if !strings.Contains(body, expected) {
			t.Fatalf("recharge page missing %q", expected)
		}
	}
	for _, removed := range []string{
		`data-cents="2000"`,
		`data-cents="5000"`,
		`data-cents="10000"`,
		`data-cents="20000"`,
	} {
		if strings.Contains(body, removed) {
			t.Fatalf("recharge page still contains %q", removed)
		}
	}
}
