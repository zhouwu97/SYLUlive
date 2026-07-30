package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/datatypes"

	"shenliyuan/internal/models"
)

type recordingCompetitionExplanationTool struct {
	userID    uint
	arguments json.RawMessage
}

func (tool *recordingCompetitionExplanationTool) Execute(
	_ context.Context,
	userID uint,
	arguments json.RawMessage,
) (interface{}, error) {
	tool.userID = userID
	tool.arguments = append(json.RawMessage(nil), arguments...)
	return map[string]interface{}{"status": "ok"}, nil
}

func TestCompetitionCandidatesRequireAuthentication(t *testing.T) {
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/user/competitions/candidates", nil)
	NewCompetitionHandler(newCompetitionTestDB(t)).ListCompetitionCandidates(context)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestCompetitionCandidatesGroupAndLegacyFitOmitScores(t *testing.T) {
	db := newCompetitionTestDB(t)
	now := time.Now()
	user := models.User{
		StudentID: "20260009", PasswordHash: "test", Nickname: "候选用户",
		StudentVerifiedAt: &now, EduAuthorized: true, EduBound: true,
		EduGrade: "本科2023级", EduCollege: "信息科学与工程学院", EduMajor: "计算机科学与技术",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	encoded := func(values ...string) datatypes.JSON {
		value, _ := json.Marshal(values)
		return datatypes.JSON(value)
	}
	eventStart := now.AddDate(0, 1, 0)
	event := models.CompetitionEvent{
		CompetitionID: "NAT-100", DatasetVersion: "catalog-v1",
		RecordHash: strings.Repeat("a", 64), Title: "程序设计竞赛", Summary: "算法与软件",
		Status: "published", SearchDisplayAllowed: true, CandidatePoolAllowed: true,
		EligibleEntryYears: encoded("2023"), EligibleColleges: encoded(),
		EligibleMajors: encoded("计算机科学与技术"), Tags: encoded("算法"),
		RiskTags: encoded("long_term_training"), BlockerCodes: encoded(),
		TimeStatus: "confirmed", TimePrecision: "exact", EventStart: &eventStart,
		RecommendationPermissionLevel: "low", AIMode: "candidate_explanation",
	}
	if err := db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	handler := NewCompetitionHandler(db)

	candidateRecorder := httptest.NewRecorder()
	candidateContext, _ := gin.CreateTestContext(candidateRecorder)
	candidateContext.Request = httptest.NewRequest(http.MethodGet, "/api/user/competitions/candidates", nil)
	candidateContext.Set("user_id", user.ID)
	handler.ListCompetitionCandidates(candidateContext)
	if candidateRecorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", candidateRecorder.Code, candidateRecorder.Body.String())
	}
	var candidateResponse struct {
		Groups []struct {
			Key   string `json:"key"`
			Items []struct {
				CompetitionID string `json:"competition_id"`
			} `json:"items"`
		} `json:"groups"`
	}
	if err := json.Unmarshal(candidateRecorder.Body.Bytes(), &candidateResponse); err != nil {
		t.Fatal(err)
	}
	if len(candidateResponse.Groups) != 1 ||
		candidateResponse.Groups[0].Key != "major_match" ||
		candidateResponse.Groups[0].Items[0].CompetitionID != "NAT-100" {
		t.Fatalf("unexpected candidate response: %s", candidateRecorder.Body.String())
	}
	for _, hidden := range []string{"record_hash", `"gates"`} {
		if strings.Contains(candidateRecorder.Body.String(), hidden) {
			t.Fatalf("student candidate response leaked %s: %s", hidden, candidateRecorder.Body.String())
		}
	}

	legacyRecorder := httptest.NewRecorder()
	legacyContext, _ := gin.CreateTestContext(legacyRecorder)
	legacyContext.Request = httptest.NewRequest(http.MethodGet, "/api/user/competitions/fit", nil)
	legacyContext.Set("user_id", user.ID)
	handler.ListFitEvents(legacyContext)
	body := legacyRecorder.Body.String()
	if legacyRecorder.Code != http.StatusOK || !strings.Contains(body, `"deprecated":true`) {
		t.Fatalf("status=%d body=%s", legacyRecorder.Code, body)
	}
	for _, forbidden := range []string{"personalized_score", "recommendation_tier"} {
		if strings.Contains(body, forbidden) {
			t.Fatalf("legacy compatibility leaked %s: %s", forbidden, body)
		}
	}
}

func TestExplainCompetitionCandidatesUsesAuthenticatedUserAndStrictInput(t *testing.T) {
	handler := NewCompetitionHandler(newCompetitionTestDB(t))
	tool := &recordingCompetitionExplanationTool{}
	handler.SetCompetitionCandidateExplanationTool(tool)

	recorder := httptest.NewRecorder()
	contextValue, _ := gin.CreateTestContext(recorder)
	contextValue.Request = httptest.NewRequest(
		http.MethodPost,
		"/api/user/competitions/candidates/explain",
		strings.NewReader(`{"competition_ids":[12,23],"question":"每周七小时"}`),
	)
	contextValue.Set("user_id", uint(42))
	handler.ExplainCompetitionCandidates(contextValue)
	if recorder.Code != http.StatusOK || tool.userID != 42 {
		t.Fatalf("status=%d user=%d body=%s", recorder.Code, tool.userID, recorder.Body.String())
	}
	if !strings.Contains(string(tool.arguments), `"event_ids":[12,23]`) {
		t.Fatalf("unexpected tool arguments: %s", tool.arguments)
	}

	badRecorder := httptest.NewRecorder()
	badContext, _ := gin.CreateTestContext(badRecorder)
	badContext.Request = httptest.NewRequest(
		http.MethodPost,
		"/api/user/competitions/candidates/explain",
		strings.NewReader(`{"competition_ids":[12,12]}`),
	)
	badContext.Set("user_id", uint(42))
	handler.ExplainCompetitionCandidates(badContext)
	if badRecorder.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", badRecorder.Code, badRecorder.Body.String())
	}
}
