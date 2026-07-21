package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/datatypes"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newCompetitionTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "handlers.db")), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(&models.WaterTeamRecruitment{}, &models.WaterTeamApplication{},
		&models.User{}, &models.CompetitionCategory{}, &models.CompetitionEvent{},
		&models.UserCompetitionCalendar{}, &models.UserCompetitionCalendarItem{},
		&models.CompetitionImportBatch{},
	); err != nil {
		t.Fatal(err)
	}
	return db
}

func TestCompetitionEventDTOExposesFailClosedGovernanceContract(t *testing.T) {
	event := models.CompetitionEvent{
		ID:                  7,
		Title:               "已核验赛事",
		RecommendationLevel: "S",
		ImportanceScore:     100,
		IsVerified:          true,
	}
	dto := competitionEventDTO(event)
	if dto.ManualRating != nil {
		t.Fatal("不得从旧推荐等级或重要分推导人工评分")
	}
	if dto.EvidenceStatus != "verified" {
		t.Fatalf("evidence_status=%q want=verified", dto.EvidenceStatus)
	}
	if dto.StrongRecommendationReady {
		t.Fatal("缺少独立审核字段时必须禁止强推荐")
	}

	encoded, err := json.Marshal(dto)
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]interface{}
	if err := json.Unmarshal(encoded, &payload); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"manual_rating", "evidence_status", "strong_recommendation_ready"} {
		if _, exists := payload[key]; !exists {
			t.Fatalf("响应缺少治理字段 %s", key)
		}
	}
}

func TestCompetitionEventDTOMarksUnverifiedEvidencePending(t *testing.T) {
	dto := competitionEventDTO(models.CompetitionEvent{Title: "待核验赛事"})
	if dto.EvidenceStatus != "pending" {
		t.Fatalf("evidence_status=%q want=pending", dto.EvidenceStatus)
	}
}

func TestCompetitionEventDTOProvidesBidirectionalRatingCompatibility(t *testing.T) {
	legacyDTO := competitionEventDTO(models.CompetitionEvent{RecommendationLevel: "A"})
	if legacyDTO.CompetitionRating != "A" || legacyDTO.RecommendationLevel != "A" {
		t.Fatalf("legacy dto ratings: new=%q old=%q", legacyDTO.CompetitionRating, legacyDTO.RecommendationLevel)
	}
	currentDTO := competitionEventDTO(models.CompetitionEvent{CompetitionRating: "S"})
	if currentDTO.CompetitionRating != "S" || currentDTO.RecommendationLevel != "S" {
		t.Fatalf("current dto ratings: new=%q old=%q", currentDTO.CompetitionRating, currentDTO.RecommendationLevel)
	}
}

func TestCompetitionOverviewBoundsUseShanghaiNaturalDays(t *testing.T) {
	location, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 10, 18, 30, 0, 0, location)
	start, end := competitionOverviewBounds(now)
	if want := time.Date(2026, 7, 10, 0, 0, 0, 0, location); !start.Equal(want) {
		t.Fatalf("start=%s want=%s", start, want)
	}
	if want := time.Date(2026, 7, 25, 0, 0, 0, 0, location); !end.Equal(want) {
		t.Fatalf("end=%s want=%s", end, want)
	}
}

func TestCompetitionOverviewCountsNaturalDayWindow(t *testing.T) {
	db := newCompetitionTestDB(t)
	start, end := competitionOverviewBounds(time.Now())
	events := []models.CompetitionEvent{
		{Title: "今天", Status: "published", RegistrationEnd: &start},
		{Title: "第十四天", Status: "published", RegistrationEnd: timePointer(end.Add(-time.Minute)), SchoolRecognitionStatus: "recognized"},
		{Title: "第十五天", Status: "published", RegistrationEnd: &end},
		{Title: "已截止", Status: "published", RegistrationEnd: timePointer(start.Add(-time.Minute))},
		{Title: "待公布", Status: "published", TimeStatus: "pending"},
		{Title: "草稿", Status: "draft", RegistrationEnd: &start},
	}
	for index := range events {
		if err := db.Create(&events[index]).Error; err != nil {
			t.Fatal(err)
		}
	}
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	NewCompetitionHandler(db).GetOverview(context)
	if recorder.Code != 200 {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response map[string]int
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response["published_total"] != 5 || response["deadline_soon_count"] != 2 ||
		response["time_pending_count"] != 1 || response["recognized_count"] != 1 {
		t.Fatalf("unexpected overview: %v", response)
	}
}

func timePointer(value time.Time) *time.Time { return &value }

func TestNormalizeEntryYear(t *testing.T) {
	now := time.Date(2026, 7, 10, 0, 0, 0, 0, time.UTC)
	for input, want := range map[string]string{
		"2023":        "2023",
		"2023级":       "2023",
		"本科2023级":     "2023",
		"2023年级":      "2023",
		"2023 / 2024": "",
		"2010级":       "",
		"没有年份":        "",
	} {
		if got := normalizeEntryYear(input, now); got != want {
			t.Errorf("normalizeEntryYear(%q)=%q want=%q", input, got, want)
		}
	}
}

func TestMatchCompetitionForProfileUsesMajorBeforeCollege(t *testing.T) {
	profile := competitionProfile{EntryYear: "2023", College: "信息科学与工程学院", Major: "计算机科学与技术"}
	event := models.CompetitionEvent{
		EligibleEntryYears: jsonArray([]string{"2023"}),
		EligibleColleges:   jsonArray([]string{"其他学院"}),
		EligibleMajors:     jsonArray([]string{"计算机科学与技术"}),
	}
	matched, level, reasons := matchCompetitionForProfile(event, profile)
	if !matched || level != "major" || len(reasons) != 2 {
		t.Fatalf("matched=%v level=%q reasons=%v", matched, level, reasons)
	}

	event.EligibleMajors = jsonArray([]string{"软件工程"})
	matched, _, _ = matchCompetitionForProfile(event, profile)
	if matched {
		t.Fatal("major mismatch must not be rescued by college")
	}
}

func TestRecommendationLevelValidation(t *testing.T) {
	for _, level := range []string{"S", "A", "B+", "B", "B-", "C", "D", "E"} {
		if got, err := normalizeRecommendationLevel(level); err != nil || got != level {
			t.Fatalf("level=%q got=%q err=%v", level, got, err)
		}
	}
	if got, err := normalizeRecommendationLevel(""); err != nil || got != "B" {
		t.Fatalf("empty got=%q err=%v", got, err)
	}
	if _, err := normalizeRecommendationLevel("A+"); err == nil {
		t.Fatal("expected invalid recommendation level to fail")
	}
}

func TestEventFromInputPrefersCompetitionRatingAndDualWrites(t *testing.T) {
	db := newCompetitionTestDB(t)
	category := models.CompetitionCategory{Name: "计算机", Slug: "computer_ai", IsActive: true}
	if err := db.Create(&category).Error; err != nil {
		t.Fatal(err)
	}
	event, err := NewCompetitionHandler(db).eventFromInput(competitionEventInput{
		Title: "评级兼容赛事", PrimaryCategoryID: category.ID,
		CompetitionRating: "A", RecommendationLevel: "B+",
	})
	if err != nil {
		t.Fatal(err)
	}
	if event.CompetitionRating != "A" || event.RecommendationLevel != "A" {
		t.Fatalf("ratings: new=%q old=%q", event.CompetitionRating, event.RecommendationLevel)
	}
}

func TestCompetitionRatingFiltersSupportNewAndLegacyQueryParameters(t *testing.T) {
	db := newCompetitionTestDB(t)
	events := []models.CompetitionEvent{
		{Title: "新字段赛事", CompetitionRating: "S", RecommendationLevel: "B", Status: "published"},
		{Title: "旧字段赛事", RecommendationLevel: "A", Status: "published"},
	}
	if err := db.Create(&events).Error; err != nil {
		t.Fatal(err)
	}
	handler := NewCompetitionHandler(db)
	for parameter, value := range map[string]string{
		"competition_rating":   "S",
		"recommendation_level": "A",
	} {
		context, _ := gin.CreateTestContext(httptest.NewRecorder())
		context.Request = httptest.NewRequest(http.MethodGet, "/?"+parameter+"="+value, nil)
		var count int64
		query := handler.applyEventFilters(context, db.Model(&models.CompetitionEvent{}))
		if err := query.Count(&count).Error; err != nil {
			t.Fatal(err)
		}
		if count != 1 {
			t.Fatalf("%s=%s count=%d want=1", parameter, value, count)
		}
	}
}

func TestCopyOfficialToCalendarIsIdempotent(t *testing.T) {
	db := newCompetitionTestDB(t)
	if _, err := models.ApplyCompetitionCalendarDedupMigration(db); err != nil {
		t.Fatal(err)
	}
	user := models.User{StudentID: "20260001", PasswordHash: "x", Nickname: "测试用户"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	category := models.CompetitionCategory{Name: "计算机", Slug: "computer", IsActive: true}
	if err := db.Create(&category).Error; err != nil {
		t.Fatal(err)
	}
	event := models.CompetitionEvent{Title: "测试比赛", PrimaryCategoryID: category.ID, Status: "published", RecommendationLevel: "A"}
	if err := db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	handler := NewCompetitionHandler(db)
	perform := func() *httptest.ResponseRecorder {
		recorder := httptest.NewRecorder()
		context, _ := gin.CreateTestContext(recorder)
		context.Params = gin.Params{{Key: "event_id", Value: fmt.Sprint(event.ID)}}
		context.Set("user_id", user.ID)
		handler.CopyOfficialToCalendar(context)
		return recorder
	}
	first := perform()
	if first.Code != 201 {
		t.Fatalf("first status=%d body=%s", first.Code, first.Body.String())
	}
	second := perform()
	if second.Code != 200 {
		t.Fatalf("second status=%d body=%s", second.Code, second.Body.String())
	}
	var response struct {
		AlreadyExists bool `json:"already_exists"`
	}
	if err := json.Unmarshal(second.Body.Bytes(), &response); err != nil || !response.AlreadyExists {
		t.Fatalf("second response=%s err=%v", second.Body.String(), err)
	}
	var count int64
	if err := db.Model(&models.UserCompetitionCalendarItem{}).
		Where("user_id = ? AND source_event_id = ?", user.ID, event.ID).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("active copies=%d want=1", count)
	}
}

func TestUserCompetitionStateUsesDatabaseProfile(t *testing.T) {
	db := newCompetitionTestDB(t)
	user := models.User{
		StudentID: "20260002", PasswordHash: "x", Nickname: "画像用户", EduBound: true,
		EduGrade: "本科2023级", EduCollege: " 信息科学与工程学院 ", EduMajor: "计算机科学与技术",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	handler := NewCompetitionHandler(db)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Set("user_id", user.ID)
	handler.GetUserCompetitionState(context)
	if recorder.Code != 200 {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response map[string]interface{}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response["profile_ready"] != true {
		t.Fatalf("unexpected state: %v", response)
	}
}

func TestNormalizeAdminImportPayloadProducesCanonicalPayload(t *testing.T) {
	db := newCompetitionTestDB(t)
	category := models.CompetitionCategory{Name: "计算机", Slug: "computer_ai", IsActive: true}
	if err := db.Create(&category).Error; err != nil {
		t.Fatal(err)
	}
	handler := NewCompetitionHandler(db)
	payload := map[string]interface{}{"events": []interface{}{map[string]interface{}{
		"title": " 测试比赛 ", "primary_category_slug": "computer_ai", "recommendation_level": "b+",
		"eligible_entry_years": []interface{}{"本科2023级"},
		"eligible_colleges":    []interface{}{" 信息科学与工程学院 "},
		"eligible_majors":      []interface{}{"计算机科学与技术"},
	}}}
	normalized, result := handler.normalizeImportPayload(payload)
	if result["error_count"] != nil {
		t.Fatalf("unexpected result shape: %v", result)
	}
	if len(result["errors"].([]gin.H)) != 0 {
		t.Fatalf("unexpected errors: %v", result["errors"])
	}
	events := normalized["events"].([]interface{})
	item := events[0].(map[string]interface{})
	if item["title"] != "测试比赛" || item["recommendation_level"] != "B+" {
		t.Fatalf("unexpected normalized item: %v", item)
	}
}

func TestAdminImportCommitReadsNormalizedPayload(t *testing.T) {
	db := newCompetitionTestDB(t)
	user := models.User{StudentID: "20260003", PasswordHash: "x", Nickname: "管理员"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	category := models.CompetitionCategory{Name: "计算机", Slug: "computer_ai", IsActive: true}
	if err := db.Create(&category).Error; err != nil {
		t.Fatal(err)
	}
	raw := []byte(`{"events":[{"title":"原始错误数据","primary_category_slug":"missing"}]}`)
	normalized := []byte(`{"events":[{"title":"规范比赛","primary_category_slug":"computer_ai","recommendation_level":"B+","eligible_entry_years":[],"eligible_colleges":[],"eligible_majors":[]}]}`)
	batch := models.CompetitionImportBatch{
		BatchID: "BATCH-TEST", UserID: user.ID, SourceType: "ai_import",
		RawPayload: datatypes.JSON(raw), NormalizedPayload: datatypes.JSON(normalized),
		ErrorSummary: datatypes.JSON([]byte(`{"errors":[]}`)), Status: "previewed",
		ExpiresAt: time.Now().Add(time.Hour), ItemCount: 1, ValidCount: 1,
	}
	if err := db.Create(&batch).Error; err != nil {
		t.Fatal(err)
	}
	body := []byte(`{"batch_id":"BATCH-TEST","selected_actions":[{"index":0,"action":"create"}]}`)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodPost, "/api/admin/competitions/import-json/commit", bytes.NewReader(body))
	context.Request.Header.Set("Content-Type", "application/json")
	context.Set("user_id", user.ID)
	NewCompetitionHandler(db).AdminImportJSONCommit(context)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var event models.CompetitionEvent
	if err := db.Where("title = ?", "规范比赛").First(&event).Error; err != nil {
		t.Fatalf("normalized event not created: %v", err)
	}
	if event.RecommendationLevel != "B+" {
		t.Fatalf("recommendation=%q", event.RecommendationLevel)
	}
	invalidNormalized := []byte(`{"events":[{"title":"不应提交","primary_category_slug":"computer_ai","recommendation_level":"B","eligible_entry_years":[],"eligible_colleges":[],"eligible_majors":[]}]}`)
	invalidBatch := models.CompetitionImportBatch{
		BatchID: "BATCH-BAD", UserID: user.ID, SourceType: "ai_import",
		RawPayload: raw, NormalizedPayload: datatypes.JSON(invalidNormalized),
		ErrorSummary: datatypes.JSON([]byte(`{"errors":[{"index":0,"field":"title"}]}`)),
		Status:       "previewed", ExpiresAt: time.Now().Add(time.Hour), ItemCount: 1,
	}
	if err := db.Create(&invalidBatch).Error; err != nil {
		t.Fatal(err)
	}
	badBody := []byte(`{"batch_id":"BATCH-BAD","selected_actions":[{"index":0,"action":"create"}]}`)
	badRecorder := httptest.NewRecorder()
	badContext, _ := gin.CreateTestContext(badRecorder)
	badContext.Request = httptest.NewRequest(http.MethodPost, "/api/admin/competitions/import-json/commit", bytes.NewReader(badBody))
	badContext.Request.Header.Set("Content-Type", "application/json")
	badContext.Set("user_id", user.ID)
	NewCompetitionHandler(db).AdminImportJSONCommit(badContext)
	if badRecorder.Code != http.StatusBadRequest {
		t.Fatalf("invalid item status=%d body=%s", badRecorder.Code, badRecorder.Body.String())
	}
}
