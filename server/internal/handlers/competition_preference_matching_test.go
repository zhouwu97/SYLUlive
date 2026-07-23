package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/models"
)

func fitEventsRequest(t *testing.T, handler *CompetitionHandler, userID uint) map[string]interface{} {
	t.Helper()
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/user/competitions/fit", nil)
	context.Set("user_id", userID)
	handler.ListFitEvents(context)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response map[string]interface{}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func createFitUser(t *testing.T, studentID string) (*CompetitionHandler, models.User) {
	t.Helper()
	db := newCompetitionTestDB(t)
	verifiedAt := time.Now()
	user := models.User{
		StudentID: studentID, StudentVerifiedAt: &verifiedAt, PasswordHash: "x", Nickname: "匹配用户",
		EduAuthorized: true, EduBound: true,
		EduGrade: "2023", EduCollege: "信息科学与工程学院", EduMajor: "计算机科学与技术",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	return NewCompetitionHandler(db), user
}

func TestCompetitionPreferenceMatchingRanksWithinProfileLevel(t *testing.T) {
	handler, user := createFitUser(t, "fit-rank-user")
	preference := models.UserCompetitionPreference{
		UserID: user.ID, Goals: jsonArray([]string{"ability"}),
		DirectionTags: jsonArray([]string{"程序设计"}), SkillTags: jsonArray([]string{"Python"}),
		PreferredRoles: jsonArray([]string{"developer"}), WeeklyHours: 7, ExperienceLevel: "beginner",
	}
	if err := handler.db.Create(&preference).Error; err != nil {
		t.Fatal(err)
	}
	events := []models.CompetitionEvent{
		{Title: "普通综合竞赛", Status: "published", EligibleMajors: jsonArray([]string{"计算机科学与技术"}), CompetitionRating: "S"},
		{Title: "Python 程序设计挑战赛", Description: "面向开发与算法能力", Status: "published", EligibleMajors: jsonArray([]string{"计算机科学与技术"}), CompetitionRating: "B"},
		{Title: "其他专业赛事", Status: "published", EligibleMajors: jsonArray([]string{"机械设计制造及其自动化"}), CompetitionRating: "S"},
	}
	if err := handler.db.Create(&events).Error; err != nil {
		t.Fatal(err)
	}

	response := fitEventsRequest(t, handler, user.ID)
	if response["preference_configured"] != true {
		t.Fatalf("preference_configured=%v", response["preference_configured"])
	}
	items := response["items"].([]interface{})
	if len(items) != 2 {
		t.Fatalf("items=%v", items)
	}
	first := items[0].(map[string]interface{})
	if first["title"] != "Python 程序设计挑战赛" || first["fit_level"] != "preference" {
		t.Fatalf("unexpected first item: %v", first)
	}
	if first["personalized_score"] == nil || first["recommendation_tier"] == nil {
		t.Fatalf("missing preference response fields: %v", first)
	}
	reasons := first["fit_reasons"].([]interface{})
	if len(reasons) < 3 {
		t.Fatalf("fit reasons=%v", reasons)
	}
}

func TestCompetitionPreferenceMatchingKeepsRatingIndependent(t *testing.T) {
	preference := models.UserCompetitionPreference{
		Goals: jsonArray([]string{"ability"}), DirectionTags: jsonArray([]string{"程序设计"}),
		ExperienceLevel: "beginner",
	}
	event := models.CompetitionEvent{
		Title: "程序设计竞赛", CompetitionRating: "B+", RecommendationLevel: "A",
	}
	matched := matchCompetitionPreference(event, "major", preference)
	if matched.Score == 0 {
		t.Fatal("expected personalized score")
	}
	if event.CompetitionRating != "B+" || event.RecommendationLevel != "A" {
		t.Fatalf("rating fields changed: %+v", event)
	}
}

func TestGraduationGapDoesNotAffectPreferenceScoreOrReasons(t *testing.T) {
	event := models.CompetitionEvent{Title: "程序设计竞赛", CompetitionRating: "A", SchoolRecognitionStatus: "recognized"}
	base := models.UserCompetitionPreference{ExperienceLevel: "beginner"}
	graduation := models.UserCompetitionPreference{Goals: jsonArray([]string{"graduation_gap"}), ExperienceLevel: "beginner"}
	baseMatch := matchCompetitionPreference(event, "major", base)
	graduationMatch := matchCompetitionPreference(event, "major", graduation)
	if graduationMatch.Score != baseMatch.Score || graduationMatch.PreferencePoints != baseMatch.PreferencePoints {
		t.Fatalf("graduation gap affected score: base=%+v graduation=%+v", baseMatch, graduationMatch)
	}
	if len(graduationMatch.Reasons) != 0 {
		t.Fatalf("graduation gap produced benefit reasons: %v", graduationMatch.Reasons)
	}
}

func TestCompetitionPreferenceMatchingExplainsTimeAndTraining(t *testing.T) {
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.Local)
	end := start.AddDate(0, 3, 0)
	preference := models.UserCompetitionPreference{
		WeeklyHours: 14, AcceptLongTermTraining: true, ExperienceLevel: "beginner",
	}
	matched := matchCompetitionPreference(models.CompetitionEvent{
		Title: "长期训练赛", RegistrationStart: &start, EventEnd: &end,
	}, "general", preference)
	if matched.TimePoints != 12 {
		t.Fatalf("time points=%d reasons=%v", matched.TimePoints, matched.Reasons)
	}
	if len(matched.Reasons) != 2 {
		t.Fatalf("time reasons=%v", matched.Reasons)
	}
}

func TestFitEventsWithoutPreferenceKeepsLegacyOrderAndShape(t *testing.T) {
	handler, user := createFitUser(t, "fit-legacy-user")
	events := []models.CompetitionEvent{
		{Title: "B 级赛事", Status: "published", EligibleMajors: jsonArray([]string{"计算机科学与技术"}), CompetitionRating: "B", ImportanceScore: 90},
		{Title: "A 级赛事", Status: "published", EligibleMajors: jsonArray([]string{"计算机科学与技术"}), CompetitionRating: "A", ImportanceScore: 10},
	}
	if err := handler.db.Create(&events).Error; err != nil {
		t.Fatal(err)
	}
	response := fitEventsRequest(t, handler, user.ID)
	if response["preference_configured"] != false {
		t.Fatalf("preference_configured=%v", response["preference_configured"])
	}
	items := response["items"].([]interface{})
	first := items[0].(map[string]interface{})
	if first["title"] != "A 级赛事" {
		t.Fatalf("legacy order changed: %v", items)
	}
	if _, exists := first["personalized_score"]; exists {
		t.Fatalf("legacy response exposed personalized score: %v", first)
	}
	if _, exists := first["recommendation_tier"]; exists {
		t.Fatalf("legacy response exposed recommendation tier: %v", first)
	}
}

func TestFitEventsReadsOnlyCurrentUserPreference(t *testing.T) {
	handler, user := createFitUser(t, "fit-isolation-user")
	other := models.User{StudentID: "fit-other-user", PasswordHash: "x", Nickname: "其他用户"}
	if err := handler.db.Create(&other).Error; err != nil {
		t.Fatal(err)
	}
	if err := handler.db.Create(&models.UserCompetitionPreference{
		UserID: other.ID, Goals: jsonArray([]string{"ability"}),
		DirectionTags: jsonArray([]string{}), SkillTags: jsonArray([]string{}),
		PreferredRoles: jsonArray([]string{}), ExperienceLevel: "beginner",
	}).Error; err != nil {
		t.Fatal(err)
	}
	if err := handler.db.Create(&models.CompetitionEvent{Title: "通用赛事", Status: "published"}).Error; err != nil {
		t.Fatal(err)
	}

	response := fitEventsRequest(t, handler, user.ID)
	if response["preference_configured"] != false {
		t.Fatalf("read another user's preference: %v", response)
	}
}
