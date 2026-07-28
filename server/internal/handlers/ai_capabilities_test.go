package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/ai"
	"shenliyuan/internal/models"
)

type capabilitiesEmptyPolicyRetriever struct{}

func (capabilitiesEmptyPolicyRetriever) Retrieve(context.Context, string) (ai.RetrievalResult, error) {
	return ai.RetrievalResult{}, nil
}

func requestAICapabilities(t *testing.T, handler *AICapabilitiesHandler, userID uint, role ...string) map[string]interface{} {
	t.Helper()
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.GET("/api/ai/capabilities", func(c *gin.Context) {
		c.Set("user_id", userID)
		if len(role) > 0 {
			c.Set("role", role[0])
		}
		handler.Get(c)
	})
	recorder := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/ai/capabilities", nil)
	router.ServeHTTP(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusOK)
	}
	var body map[string]interface{}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	return body
}

func TestAICapabilitiesDisabled(t *testing.T) {
	body := requestAICapabilities(t, NewAICapabilitiesHandler(false, true, []string{"7"}), 7)
	if body["enabled"] != false || body["access_allowed"] != false {
		t.Fatalf("unexpected disabled response: %#v", body)
	}
}

func TestAICapabilitiesInternalWhitelist(t *testing.T) {
	handler := NewAICapabilitiesHandler(true, true, []string{" 7 ", "39"})
	allowed := requestAICapabilities(t, handler, 7)
	denied := requestAICapabilities(t, handler, 8)
	if allowed["access_allowed"] != true || denied["access_allowed"] != false {
		t.Fatalf("whitelist result mismatch: allowed=%#v denied=%#v", allowed, denied)
	}
	if _, leaked := allowed["api_key"]; leaked {
		t.Fatal("capabilities response must not expose provider credentials")
	}
	if allowed["chat_enabled"] != false || allowed["phase"] != "p0" {
		t.Fatalf("P0 contract mismatch: %#v", allowed)
	}
}

func TestAICapabilitiesAdministratorsCanEnterInternalTest(t *testing.T) {
	handler := NewAICapabilitiesHandler(true, true, []string{"7"})
	admin := requestAICapabilities(t, handler, 8, "admin")
	superAdmin := requestAICapabilities(t, handler, 9, "super_admin")
	if admin["access_allowed"] != true || superAdmin["access_allowed"] != true {
		t.Fatalf("administrators should be allowed: admin=%#v super=%#v", admin, superAdmin)
	}
}

func TestAICapabilitiesPublicAccess(t *testing.T) {
	body := requestAICapabilities(t, NewAICapabilitiesHandler(true, false, nil), 99)
	if body["access_allowed"] != true {
		t.Fatalf("expected public access: %#v", body)
	}
	if body["max_message_chars"] != float64(20) {
		t.Fatalf("default max_message_chars mismatch: %#v", body)
	}
}

func TestAICapabilitiesDoesNotExposeRetiredServerScheduleFeature(t *testing.T) {
	body := requestAICapabilities(t, NewAICapabilitiesHandler(true, false, nil), 99)
	features, ok := body["features"].(map[string]interface{})
	if !ok {
		t.Fatalf("features = %#v, want object", body["features"])
	}
	if features["schedule_windows"] != false {
		t.Fatalf("retired schedule skill must stay unavailable: %#v", features)
	}
}

func TestAICapabilitiesReturnsUnlimitedQuotaForVerifiedStudent(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:%s?mode=memory&cache=shared", uuid.NewString())), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}); err != nil {
		t.Fatalf("migrate user: %v", err)
	}
	verifiedAt := time.Now()
	user := models.User{
		ID: 77, StudentID: "2403130233", StudentVerifiedAt: &verifiedAt,
		PasswordHash: "test", AccountStatus: "active",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	runtime, err := ai.NewRuntime(db, &ai.MockProvider{}, capabilitiesEmptyPolicyRetriever{}, ai.NewEventBroker(), ai.RuntimeConfig{
		ProviderName: "mock", Model: "mock", RequestTimeout: 5 * time.Second,
		MaxMessageChars: 20, HourlyMessageLimit: 3,
		UnlimitedStudentIDs:         []string{"2403130233"},
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
		AuditHashSecret: "test-secret",
	})
	if err != nil {
		t.Fatalf("create runtime: %v", err)
	}
	handler := NewAICapabilitiesHandler(true, false, nil, AICapabilitiesOptions{
		Runtime: runtime, PolicyRAGEnabled: true, HourlyLimit: 3, MaxMessageChars: 20,
	})
	body := requestAICapabilities(t, handler, user.ID)
	quota, ok := body["quota"].(map[string]interface{})
	if !ok || quota["unlimited"] != true || quota["remaining"] != float64(3) {
		t.Fatalf("unexpected unlimited quota: %#v", body["quota"])
	}
}
