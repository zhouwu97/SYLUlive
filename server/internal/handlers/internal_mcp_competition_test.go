package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"gorm.io/datatypes"

	"shenliyuan/internal/models"
)

func TestInternalMCPCompetitionGatewayRequiresGrantAndHidesBlockers(t *testing.T) {
	db := newCompetitionTestDB(t)
	encoded := func(values ...string) datatypes.JSON {
		value, _ := json.Marshal(values)
		return datatypes.JSON(value)
	}
	event := models.CompetitionEvent{
		CompetitionID: "NAT-MCP-1", DatasetVersion: "mcp-v1",
		RecordHash: strings.Repeat("b", 64), Title: "MCP 赛事", Status: "published",
		SearchDisplayAllowed: true, CandidatePoolAllowed: true,
		Tags: encoded(), EligibleEntryYears: encoded(), EligibleColleges: encoded(),
		EligibleMajors: encoded(), RiskTags: encoded("long_term_training"),
		BlockerCodes:                  encoded("internal-secret-blocker"),
		RecommendationPermissionLevel: "low", AIMode: "candidate_explanation",
	}
	if err := db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	handler := NewCompetitionHandler(db)
	router := gin.New()
	group := router.Group("/internal/mcp")
	group.Use(InternalMCPGrantMiddleware("test-grant"))
	group.POST("/competition/candidate-context", handler.InternalMCPCompetitionCandidateContext)
	group.POST("/competition/verify-records", handler.InternalMCPCompetitionVerifyRecords)

	body := []byte(`{"competition_ids":["NAT-MCP-1"]}`)
	unauthorized := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/internal/mcp/competition/candidate-context", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(unauthorized, request)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", unauthorized.Code, unauthorized.Body.String())
	}

	authorized := httptest.NewRecorder()
	request = httptest.NewRequest(http.MethodPost, "/internal/mcp/competition/candidate-context", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer test-grant")
	router.ServeHTTP(authorized, request)
	if authorized.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", authorized.Code, authorized.Body.String())
	}
	if strings.Contains(authorized.Body.String(), "internal-secret-blocker") ||
		strings.Contains(authorized.Body.String(), "blocker_codes") {
		t.Fatalf("内部阻断码泄露: %s", authorized.Body.String())
	}

	verifyBody := []byte(`{"records":[{"competition_id":"NAT-MCP-1","record_hash":"changed"}]}`)
	verify := httptest.NewRecorder()
	request = httptest.NewRequest(http.MethodPost, "/internal/mcp/competition/verify-records", bytes.NewReader(verifyBody))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer test-grant")
	router.ServeHTTP(verify, request)
	if verify.Code != http.StatusOK || !strings.Contains(verify.Body.String(), "record_hash_changed") {
		t.Fatalf("status=%d body=%s", verify.Code, verify.Body.String())
	}
}

func TestInternalMCPCompetitionGatewayRejectsUnknownFields(t *testing.T) {
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(
		http.MethodPost,
		"/internal/mcp/competition/details",
		bytes.NewReader([]byte(`{"competition_ids":["NAT-1"],"forged":true}`)),
	)
	NewCompetitionHandler(newCompetitionTestDB(t)).InternalMCPCompetitionDetails(context)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}
