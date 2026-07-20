package ai

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"gorm.io/datatypes"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/academiccalendar"
	"shenliyuan/internal/models"
)

type fixedScheduleReader struct {
	courses  []CachedCourse
	userID   uint
	year     string
	semester int
}

func (r *fixedScheduleReader) Read(_ context.Context, userID uint, year string, semester int) ([]CachedCourse, error) {
	r.userID, r.year, r.semester = userID, year, semester
	return r.courses, nil
}

func TestScheduleSkillUsesExplicitWeekMappingAndReviewedPeriods(t *testing.T) {
	require.NoError(t, academiccalendar.InitializeTimezone())
	db, err := gorm.Open(sqlite.Open("file:schedule-skill?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.CampusCalendar{}, &models.ClassPeriodProfile{}))
	calendarJSON := `{
		"schema_version":2,"academic_year":"2026-2027",
		"semesters":[{"edu_semester_code":3,"start_date":"2026-08-31","end_date":"2027-01-15",
		"teaching_weeks":[{"week":1,"start_date":"2026-08-31","end_date":"2026-09-06"}]}],
		"day_overrides":[]}`
	require.NoError(t, db.Create(&models.CampusCalendar{
		AcademicYear: "2026-2027", Version: 1, Status: "published", Data: datatypes.JSON(calendarJSON),
	}).Error)
	periods := []map[string]interface{}{}
	starts := []string{"08:00", "08:55", "10:00", "10:55", "13:30", "14:25", "15:30", "16:25"}
	ends := []string{"08:45", "09:40", "10:45", "11:40", "14:15", "15:10", "16:15", "17:10"}
	for index := range starts {
		periods = append(periods, map[string]interface{}{"section": index + 1, "start_time": starts[index], "end_time": ends[index]})
	}
	periodJSON, _ := json.Marshal(periods)
	require.NoError(t, db.Create(&models.ClassPeriodProfile{
		AcademicYear: "2026-2027", Name: "标准节次", Status: "published", Periods: periodJSON,
		EffectiveFrom: time.Date(2026, 8, 31, 0, 0, 0, 0, academiccalendar.ShanghaiLocation),
		EffectiveTo:   time.Date(2027, 1, 15, 23, 59, 0, 0, academiccalendar.ShanghaiLocation),
	}).Error)
	reader := &fixedScheduleReader{courses: []CachedCourse{
		{CourseCode: "A", OriginalName: "课程A", Weekday: 2, StartSection: 1, EndSection: 2, Weeks: []int{1}, Semester: 3},
		// 该课程只在第 2 周生效，不能靠当前周奇偶重新推断。
		{CourseCode: "B", OriginalName: "课程B", Weekday: 2, StartSection: 5, EndSection: 6, Weeks: []int{2}, Semester: 3},
	}}
	skill := NewScheduleSkill(db, reader)
	skill.now = func() time.Time { return time.Date(2026, 9, 1, 9, 0, 0, 0, academiccalendar.ShanghaiLocation) }
	result, err := skill.Execute(context.Background(), 42, ScheduleWindowsArguments{
		Scope: "today", MinimumFreeMinutes: 120, PreferredDaypart: "afternoon",
	})
	require.NoError(t, err)
	require.Equal(t, "ok", result.Status)
	require.Len(t, result.Days, 1)
	require.Equal(t, 1, result.Days[0].TeachingWeek)
	require.Len(t, result.Days[0].Courses, 1)
	require.Equal(t, uint(42), reader.userID)
	require.Equal(t, "2026-2027", reader.year)
	require.Equal(t, 3, reader.semester)
	require.NotEmpty(t, result.Days[0].FreeWindows)
}

func TestScheduleSkillV1CalendarIsUnavailable(t *testing.T) {
	require.NoError(t, academiccalendar.InitializeTimezone())
	db, err := gorm.Open(sqlite.Open("file:schedule-v1?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.CampusCalendar{}, &models.ClassPeriodProfile{}))
	raw := `{"schema_version":1,"academic_year":"2026-2027","semesters":[{"start_date":"2026-08-31","end_date":"2027-01-15"}]}`
	require.NoError(t, db.Create(&models.CampusCalendar{AcademicYear: "2026-2027", Version: 1, Status: "published", Data: datatypes.JSON(raw)}).Error)
	skill := NewScheduleSkill(db, &fixedScheduleReader{})
	skill.now = func() time.Time { return time.Date(2026, 9, 1, 9, 0, 0, 0, academiccalendar.ShanghaiLocation) }
	result, err := skill.Execute(context.Background(), 7, ScheduleWindowsArguments{Scope: "today", MinimumFreeMinutes: 60})
	require.NoError(t, err)
	require.Equal(t, "data_unavailable", result.Status)
	require.Equal(t, "edu_semester_mapping_missing", result.Reason)
}

func TestScheduleToolRejectsModelSuppliedIdentity(t *testing.T) {
	tool := NewScheduleWindowsTool(nil)
	_, err := tool.Execute(context.Background(), 7, json.RawMessage(`{"scope":"today","minimum_free_minutes":60,"user_id":99}`))
	require.Error(t, err)
}
