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

type capabilitiesTool struct{ name string }

func (tool capabilitiesTool) Name() string    { return tool.name }
func (tool capabilitiesTool) Version() string { return "test" }
func (tool capabilitiesTool) Definition() ai.ToolDefinition {
	return ai.ToolDefinition{Name: tool.name, Parameters: map[string]interface{}{"type": "object"}}
}
func (tool capabilitiesTool) Execute(context.Context, uint, json.RawMessage) (interface{}, error) {
	return map[string]interface{}{}, nil
}

type capabilitiesExternalMCPHealth struct{ healthy bool }

func (health *capabilitiesExternalMCPHealth) Healthy() bool { return health.healthy }

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
	body := requestAICapabilities(t, NewAICapabilitiesHandler(false), 7)
	if body["enabled"] != false || body["access_allowed"] != false {
		t.Fatalf("unexpected disabled response: %#v", body)
	}
}

func TestAICapabilitiesUsesSameAccessForAllAuthenticatedUsers(t *testing.T) {
	handler := NewAICapabilitiesHandler(true)
	user := requestAICapabilities(t, handler, 7, "user")
	admin := requestAICapabilities(t, handler, 8, "admin")
	if user["access_allowed"] != true || admin["access_allowed"] != true {
		t.Fatalf("access should not depend on role: user=%#v admin=%#v", user, admin)
	}
	if user["internal_test_only"] != false || admin["internal_test_only"] != false {
		t.Fatalf("internal access restriction must stay disabled: user=%#v admin=%#v", user, admin)
	}
	if _, leaked := user["api_key"]; leaked {
		t.Fatal("capabilities response must not expose provider credentials")
	}
	if user["chat_enabled"] != false || user["phase"] != "p0" {
		t.Fatalf("P0 contract mismatch: %#v", user)
	}
}

func TestAICapabilitiesPublicAccess(t *testing.T) {
	body := requestAICapabilities(t, NewAICapabilitiesHandler(true), 99)
	if body["access_allowed"] != true {
		t.Fatalf("expected public access: %#v", body)
	}
	if body["max_message_chars"] != float64(500) {
		t.Fatalf("default max_message_chars mismatch: %#v", body)
	}
}

func TestAICapabilitiesDoesNotExposeRetiredServerScheduleFeature(t *testing.T) {
	body := requestAICapabilities(t, NewAICapabilitiesHandler(true), 99)
	features, ok := body["features"].(map[string]interface{})
	if !ok {
		t.Fatalf("features = %#v, want object", body["features"])
	}
	if features["schedule_windows"] != false {
		t.Fatalf("retired schedule skill must stay unavailable: %#v", features)
	}
}

func TestAICapabilitiesReportsOnlyHealthyRegisteredHy3Features(t *testing.T) {
	registry, err := ai.NewToolRegistry(nil,
		capabilitiesTool{name: "hy3_decision.explain_competition_candidates"},
		capabilitiesTool{name: "hy3_decision.compare_competitions"},
		capabilitiesTool{name: "hy3_decision.analyze_academic"},
		capabilitiesTool{name: "hy3_decision.plan_student_week"},
	)
	if err != nil {
		t.Fatalf("create tool registry: %v", err)
	}
	health := &capabilitiesExternalMCPHealth{healthy: true}
	handler := NewAICapabilitiesHandler(true, AICapabilitiesOptions{
		ExternalMCPConfigured: true,
		ExternalMCPHealth:     health,
		ToolRegistry:          registry,
	})

	body := requestAICapabilities(t, handler, 99)
	features := body["features"].(map[string]interface{})
	for _, name := range []string{
		"hy3_competition_explain", "hy3_competition_compare", "hy3_academic_analysis", "hy3_week_plan",
	} {
		if features[name] != true {
			t.Fatalf("feature %s should be available: %#v", name, features)
		}
	}

	health.healthy = false
	body = requestAICapabilities(t, handler, 99)
	features = body["features"].(map[string]interface{})
	for _, name := range []string{
		"hy3_competition_explain", "hy3_competition_compare", "hy3_academic_analysis", "hy3_week_plan",
	} {
		if features[name] != false {
			t.Fatalf("feature %s must fail closed: %#v", name, features)
		}
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
	handler := NewAICapabilitiesHandler(true, AICapabilitiesOptions{
		Runtime: runtime, PolicyRAGEnabled: true, HourlyLimit: 3, MaxMessageChars: 200,
	})
	body := requestAICapabilities(t, handler, user.ID)
	if body["chat_enabled"] != true || body["access_allowed"] != true {
		t.Fatalf("authenticated user should have chat access: %#v", body)
	}
	quota, ok := body["quota"].(map[string]interface{})
	if !ok || quota["unlimited"] != true || quota["remaining"] != float64(3) {
		t.Fatalf("unexpected unlimited quota: %#v", body["quota"])
	}
}
