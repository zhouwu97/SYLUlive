package academiccalendar

import (
	"testing"
	"time"
)

func TestV1CalendarReturnsUnavailableSemesterMapping(t *testing.T) {
	if err := InitializeTimezone(); err != nil {
		t.Fatal(err)
	}
	result, err := ResolveSemesterMapping([]byte(`{"schema_version":1,"academic_year":"2026-2027","semesters":[{"id":"fall","name":"第一学期","start_date":"2026-08-31","end_date":"2027-01-15"}]}`), time.Date(2026, 9, 1, 0, 0, 0, 0, ShanghaiLocation))
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != "data_unavailable" || result.Reason != "edu_semester_mapping_missing" || result.CalendarSchemaVersion != 1 {
		t.Fatalf("v1 兼容结果错误: %#v", result)
	}
}

func TestV2CalendarUsesExplicitSemesterCode(t *testing.T) {
	if err := InitializeTimezone(); err != nil {
		t.Fatal(err)
	}
	result, err := ResolveSemesterMapping([]byte(`{"schema_version":2,"academic_year":"2026-2027","semesters":[{"id":"fall","name":"第一学期","edu_semester_code":3,"start_date":"2026-08-31","end_date":"2027-01-15"}]}`), time.Date(2026, 9, 1, 0, 0, 0, 0, ShanghaiLocation))
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != "ok" || result.EduSemesterCode != 3 || result.AcademicYear != "2026-2027" {
		t.Fatalf("v2 学期映射错误: %#v", result)
	}
}
