package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/models"
)

func dashboardRequest(t *testing.T, handler gin.HandlerFunc, userID uint) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/user/competitions/dashboard", nil)
	if userID != 0 {
		context.Set("user_id", userID)
	}
	handler(context)
	return recorder
}

func TestCompetitionDashboardSummarizesAllStatusesWithoutLeakingUsers(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)

	preference := models.UserCompetitionPreference{
		UserID: 51, Goals: jsonArray([]string{"ability", "resume"}),
		DirectionTags: jsonArray([]string{"算法"}), SkillTags: jsonArray([]string{}),
		PreferredRoles: jsonArray([]string{}), WeeklyHours: 7, ExperienceLevel: "beginner",
	}
	if err := db.Create(&preference).Error; err != nil {
		t.Fatal(err)
	}
	for _, status := range []string{"verified", "self_reported", "pending", "rejected", "pending"} {
		award := models.UserCompetitionAward{
			UserID: 51, CompetitionTitle: "测试赛事", CompetitionYear: 2026,
			AwardName: "参与", CompetitionStage: "school", Role: "member",
			SkillTags: jsonArray([]string{}), EvidenceFileIDs: uintJSONArray([]uint{}),
			VerificationStatus: status, Visibility: "private",
		}
		if err := db.Create(&award).Error; err != nil {
			t.Fatal(err)
		}
	}
	other := models.UserCompetitionAward{
		UserID: 52, CompetitionTitle: "其他用户赛事", CompetitionYear: 2026,
		AwardName: "参与", CompetitionStage: "school", Role: "member",
		SkillTags: jsonArray([]string{}), EvidenceFileIDs: uintJSONArray([]uint{}),
		VerificationStatus: "verified", Visibility: "private",
	}
	if err := db.Create(&other).Error; err != nil {
		t.Fatal(err)
	}

	recorder := dashboardRequest(t, handler.GetCompetitionDashboard, 51)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response competitionDashboardSummaryResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if !response.PreferenceConfigured || response.PrimaryGoal != "ability" ||
		response.PrimaryDirection != "算法" || response.WeeklyHours != 7 {
		t.Fatalf("unexpected preference summary: %+v", response)
	}
	if response.AwardTotal != 5 || response.VerifiedAwardCount != 1 ||
		response.SelfReportedAwardCount != 1 || response.PendingAwardCount != 2 ||
		response.RejectedAwardCount != 1 || !response.CapabilityReady {
		t.Fatalf("unexpected award summary: %+v", response)
	}
}

func TestCompetitionDashboardReturnsEmptySummaryForUnsetUser(t *testing.T) {
	recorder := dashboardRequest(t, NewCompetitionHandler(newCompetitionTestDB(t)).GetCompetitionDashboard, 99)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response competitionDashboardSummaryResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.PreferenceConfigured || response.AwardTotal != 0 || response.CapabilityReady {
		t.Fatalf("unexpected empty summary: %+v", response)
	}
}

func TestCompetitionDashboardRequiresAuthentication(t *testing.T) {
	recorder := dashboardRequest(t, NewCompetitionHandler(newCompetitionTestDB(t)).GetCompetitionDashboard, 0)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}
