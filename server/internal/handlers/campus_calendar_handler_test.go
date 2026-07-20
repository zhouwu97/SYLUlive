package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/datatypes"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

func TestValidateCampusCalendarAcceptsStructuredCalendar(t *testing.T) {
	raw := []byte(`{
        "schema_version": 1,
        "calendar_id": "sylu-2026-2027",
        "school": "测试大学",
        "academic_year": "2026-2027",
        "timezone": "Asia/Shanghai",
        "source": {"type":"official_calendar_image","title":"官方校历","file_name":"calendar.jpg","verified":true},
        "semesters": [{
            "id":"fall","name":"第一学期","start_date":"2026-09-01","end_date":"2026-09-30",
            "teaching_weeks":[
                {"week":1,"start_date":"2026-09-01","end_date":"2026-09-06"},
                {"week":2,"start_date":"2026-09-07","end_date":"2026-09-13"}
            ]
        }],
        "events": [{"id":"holiday","title":"校庆假期","type":"holiday","start_date":"2026-09-10","end_date":"2026-09-11"}],
        "day_overrides": [{"date":"2026-09-12","day_mode":"makeup_teaching","schedule_as_weekday":3}]
    }`)

	result, document := validateCampusCalendar(raw)
	if !result.Valid {
		t.Fatalf("expected valid calendar, errors: %#v", result.Errors)
	}
	if document.AcademicYear != "2026-2027" {
		t.Fatalf("unexpected academic year: %s", document.AcademicYear)
	}
}

func TestValidateCampusCalendarRejectsOverlappingTeachingWeeks(t *testing.T) {
	raw := []byte(`{
        "schema_version": 1,
        "calendar_id": "sylu-2026-2027",
        "school": "测试大学",
        "academic_year": "2026-2027",
        "timezone": "Asia/Shanghai",
        "source": {"type":"official_calendar_image","title":"官方校历","file_name":"calendar.jpg","verified":true},
        "semesters": [{
            "id":"fall","name":"第一学期","start_date":"2026-09-01","end_date":"2026-09-30",
            "teaching_weeks":[
                {"week":1,"start_date":"2026-09-01","end_date":"2026-09-08"},
                {"week":2,"start_date":"2026-09-08","end_date":"2026-09-13"}
            ]
        }]
    }`)

	result, _ := validateCampusCalendar(raw)
	if result.Valid {
		t.Fatal("expected overlapping teaching weeks to be rejected")
	}
}

func TestValidateCampusCalendarRejectsDuplicateOverrides(t *testing.T) {
	raw := []byte(`{
        "schema_version": 1,
        "calendar_id": "sylu-2026-2027",
        "school": "测试大学",
        "academic_year": "2026-2027",
        "timezone": "Asia/Shanghai",
        "source": {"type":"official_calendar_image","title":"官方校历","file_name":"calendar.jpg","verified":true},
        "semesters": [{"id":"fall","name":"第一学期","start_date":"2026-09-01","end_date":"2026-09-30","teaching_weeks":[]}],
        "day_overrides": [
            {"date":"2026-09-12","day_mode":"makeup_teaching","schedule_as_weekday":3},
            {"date":"2026-09-12","day_mode":"makeup_teaching","schedule_as_weekday":3}
        ]
    }`)

	result, _ := validateCampusCalendar(raw)
	if result.Valid {
		t.Fatal("expected duplicate day override to be rejected")
	}
}

func TestValidateCampusCalendarAcceptsV2SemesterMappings(t *testing.T) {
	raw := []byte(`{
        "schema_version": 2,
        "calendar_id": "sylu-2026-2027",
        "school": "测试大学",
        "academic_year": "2026-2027",
        "timezone": "Asia/Shanghai",
        "source": {"type":"official_calendar_image","title":"官方校历","file_name":"calendar.jpg","verified":true},
        "semesters": [
            {"id":"fall","name":"第一学期","edu_semester_code":3,"start_date":"2026-09-01","end_date":"2027-01-15","teaching_weeks":[]},
            {"id":"spring","name":"第二学期","edu_semester_code":12,"start_date":"2027-02-22","end_date":"2027-07-16","teaching_weeks":[]}
        ]
    }`)

	result, _ := validateCampusCalendar(raw)
	if !result.Valid {
		t.Fatalf("v2 校历应通过校验: %#v", result.Errors)
	}
}

func TestValidateCampusCalendarRejectsInvalidV2SemesterMappings(t *testing.T) {
	tests := []struct {
		name      string
		semesters string
	}{
		{"缺少代码", `[{"id":"fall","name":"第一学期","start_date":"2026-09-01","end_date":"2027-01-15","teaching_weeks":[]}]`},
		{"非法代码", `[{"id":"fall","name":"第一学期","edu_semester_code":1,"start_date":"2026-09-01","end_date":"2027-01-15","teaching_weeks":[]}]`},
		{"重复代码", `[{"id":"fall","name":"第一学期","edu_semester_code":3,"start_date":"2026-09-01","end_date":"2027-01-15","teaching_weeks":[]},{"id":"spring","name":"第二学期","edu_semester_code":3,"start_date":"2027-02-22","end_date":"2027-07-16","teaching_weeks":[]}]`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			raw := []byte(`{"schema_version":2,"calendar_id":"sylu-2026-2027","school":"测试大学","academic_year":"2026-2027","timezone":"Asia/Shanghai","source":{"type":"official_calendar_image","title":"官方校历","file_name":"calendar.jpg","verified":true},"semesters":` + tt.semesters + `}`)
			result, _ := validateCampusCalendar(raw)
			if result.Valid {
				t.Fatal("无效 v2 学期映射不应通过")
			}
		})
	}
}

func TestGetCurrentCampusCalendarUsesNewestAcademicYearAndDatabaseVersion(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "calendar.db")), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get database handle: %v", err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(&models.CampusCalendar{}); err != nil {
		t.Fatalf("migrate calendar: %v", err)
	}

	newerPublishedAt := time.Now()
	olderPublishedAt := newerPublishedAt.Add(-time.Hour)
	calendars := []models.CampusCalendar{
		{
			AcademicYear: "2026-2027",
			Version:      2,
			Status:       "published",
			Data:         datatypes.JSON([]byte(`{"schema_version":1,"academic_year":"2026-2027","version":1}`)),
			SourceHash:   "new-year-revision",
			PublishedAt:  &olderPublishedAt,
		},
		{
			AcademicYear: "2025-2026",
			Version:      9,
			Status:       "published",
			Data:         datatypes.JSON([]byte(`{"schema_version":1,"academic_year":"2025-2026","version":9}`)),
			SourceHash:   "old-year-revision",
			PublishedAt:  &newerPublishedAt,
		},
	}
	if err := db.Create(&calendars).Error; err != nil {
		t.Fatalf("seed calendars: %v", err)
	}

	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	NewCampusCalendarHandler(db).GetCurrent(context)

	if recorder.Code != 200 {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response struct {
		Calendar map[string]interface{} `json:"calendar"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if got := response.Calendar["academic_year"]; got != "2026-2027" {
		t.Fatalf("academic_year=%v want 2026-2027", got)
	}
	if got := response.Calendar["version"]; got != float64(2) {
		t.Fatalf("version=%v want 2", got)
	}
}

func TestWriteCampusCalendarUsesDatabaseVersion(t *testing.T) {
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	calendar := models.CampusCalendar{
		AcademicYear: "2026-2027",
		Version:      3,
		Status:       "published",
		Data:         datatypes.JSON([]byte(`{"schema_version":1,"academic_year":"2026-2027","version":1}`)),
		SourceHash:   "database-revision",
	}

	NewCampusCalendarHandler(nil).writeCalendar(context, calendar)

	var response struct {
		Calendar map[string]interface{} `json:"calendar"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if got := response.Calendar["version"]; got != float64(3) {
		t.Fatalf("version=%v want 3", got)
	}
}

func TestPublishV2CalendarRejectsUnresolvedItems(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "calendar-unresolved.db")), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(&models.CampusCalendar{}); err != nil {
		t.Fatal(err)
	}
	document := models.CampusCalendar{
		AcademicYear: "2026-2027", Version: 1, Status: "draft", SourceHash: "unresolved",
		Data: datatypes.JSON([]byte(`{
            "schema_version":2,"calendar_id":"sylu-2026-2027","school":"测试大学",
            "academic_year":"2026-2027","timezone":"Asia/Shanghai",
            "source":{"type":"official_calendar_image","title":"官方校历","file_name":"calendar.jpg","verified":true},
            "semesters":[{"id":"fall","name":"第一学期","edu_semester_code":3,"start_date":"2026-09-01","end_date":"2027-01-15","teaching_weeks":[]}],
            "unresolved_items":[{"path":"day_overrides","reason":"调休待核验"}]
        }`)),
	}
	if err := db.Create(&document).Error; err != nil {
		t.Fatal(err)
	}
	response := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(response)
	context.Params = gin.Params{{Key: "id", Value: strconv.FormatUint(uint64(document.ID), 10)}}
	NewCampusCalendarHandler(db).Publish(context)
	if response.Code != http.StatusUnprocessableEntity {
		t.Fatalf("存在待确认项的 v2 校历不应发布: status=%d body=%s", response.Code, response.Body.String())
	}
}
