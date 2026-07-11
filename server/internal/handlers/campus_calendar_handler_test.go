package handlers

import "testing"

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
