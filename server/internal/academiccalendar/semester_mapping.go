package academiccalendar

import (
	"encoding/json"
	"fmt"
	"time"
)

// SemesterMappingResult 是课表 Skill 在读取校历映射时的稳定结果。
type SemesterMappingResult struct {
	Status                string `json:"status"`
	Reason                string `json:"reason,omitempty"`
	CalendarSchemaVersion int    `json:"calendar_schema_version"`
	SuggestedAction       string `json:"suggested_action,omitempty"`
	AcademicYear          string `json:"academic_year,omitempty"`
	EduSemesterCode       int    `json:"edu_semester_code,omitempty"`
}

type semesterMappingDocument struct {
	SchemaVersion int    `json:"schema_version"`
	AcademicYear  string `json:"academic_year"`
	Semesters     []struct {
		EduSemesterCode *int   `json:"edu_semester_code"`
		StartDate       string `json:"start_date"`
		EndDate         string `json:"end_date"`
	} `json:"semesters"`
}

// ResolveSemesterMapping 只接受 v2 显式映射，绝不根据名称、ID 或月份猜测。
func ResolveSemesterMapping(raw []byte, date time.Time) (SemesterMappingResult, error) {
	var document semesterMappingDocument
	if err := json.Unmarshal(raw, &document); err != nil {
		return SemesterMappingResult{}, fmt.Errorf("decode campus calendar: %w", err)
	}
	if document.SchemaVersion == 1 {
		return unavailableMapping(1), nil
	}
	if document.SchemaVersion != 2 {
		return SemesterMappingResult{}, fmt.Errorf("unsupported calendar schema version: %d", document.SchemaVersion)
	}
	if ShanghaiLocation == nil {
		return SemesterMappingResult{}, fmt.Errorf("Asia/Shanghai timezone is not initialized")
	}
	localDate := date.In(ShanghaiLocation).Format("2006-01-02")
	for _, semester := range document.Semesters {
		if localDate < semester.StartDate || localDate > semester.EndDate {
			continue
		}
		if semester.EduSemesterCode == nil || (*semester.EduSemesterCode != 3 && *semester.EduSemesterCode != 12) {
			return unavailableMapping(2), nil
		}
		return SemesterMappingResult{
			Status:                "ok",
			CalendarSchemaVersion: 2,
			AcademicYear:          document.AcademicYear,
			EduSemesterCode:       *semester.EduSemesterCode,
		}, nil
	}
	return SemesterMappingResult{
		Status:                "data_unavailable",
		Reason:                "date_outside_published_semesters",
		CalendarSchemaVersion: 2,
		SuggestedAction:       "请联系管理员核验当前校历",
	}, nil
}

func unavailableMapping(schemaVersion int) SemesterMappingResult {
	return SemesterMappingResult{
		Status:                "data_unavailable",
		Reason:                "edu_semester_mapping_missing",
		CalendarSchemaVersion: schemaVersion,
		SuggestedAction:       "请等待管理员发布新版校历",
	}
}
