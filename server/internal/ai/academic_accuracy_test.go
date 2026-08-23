package ai

import (
	"encoding/json"
	"testing"
)

func TestSummarizeGradesDeduplicatesRetakesAndKeepsTextPass(t *testing.T) {
	raw := json.RawMessage(`{
		"grades":[
			{"course_name":"信号与系统","credits":3,"gpa":0,"fraction":55.8},
			{"course_name":"信号与系统","credits":3,"gpa":1,"fraction":60.1},
			{"course_name":"高等数学","credits":4,"gpa":4,"fraction":0,"grade":"优秀"}
		],
		"covered_terms":[{"scope_key":"2025-2026:3"},{"scope_key":"2025-2026:12"}]
	}`)

	summary := summarizeGrades(raw)
	if summary.CourseCount != 2 {
		t.Fatalf("expected two unique courses, got %d", summary.CourseCount)
	}
	if summary.FailedCourseCount != 0 || len(summary.FailedCourses) != 0 {
		t.Fatalf("passed retake/text grade was treated as failed: %+v", summary)
	}
	if len(summary.CoveredTerms) != 2 {
		t.Fatalf("expected two covered terms, got %v", summary.CoveredTerms)
	}
}

func TestAcademicRiskFallbackStatesCoverageAndVerifiedFacts(t *testing.T) {
	raw := json.RawMessage(`{
		"status":"available",
		"data":{
			"risk_level":"incomplete",
			"grades":{"course_count":28,"total_credits":64,"weighted_gpa":2.11,"covered_terms":["2025-2026 第一学期","2025-2026 第二学期"]},
			"risks":["发现 2 门未通过课程（信号与系统、计算机网络）"],
			"actions":["核对未通过课程安排"],
			"to_confirm":["成绩快照覆盖不完整"]
		},
		"warnings":[]
	}`)

	fallback, riskSeen := academicRiskFallback("academic.get_risk_analysis", raw)
	if !riskSeen {
		t.Fatal("expected incomplete academic result to be treated as risky")
	}
	for _, expected := range []string{"28 门课程", "64 学分", "加权 GPA 2.11", "2025-2026 第一学期", "信号与系统"} {
		if !containsAny(fallback, expected) {
			t.Fatalf("fallback omitted verified fact %q: %s", expected, fallback)
		}
	}
	if !academicAnswerNeedsGuard("没有观察到挂科风险，本次成绩很好。", fallback, riskSeen) {
		t.Fatal("contradictory no-risk answer was not guarded")
	}
}

func TestAcademicRiskFinalAnswerAlwaysUsesVerifiedFacts(t *testing.T) {
	const verified = "基于当前已授权快照，主要风险：信号与系统未通过。"
	if got := academicRiskFinalAnswer("我暂时无法从已发布的校园资料中核验这项具体信息。", verified, true); got != verified {
		t.Fatalf("expected verified academic facts to replace generic answer, got %q", got)
	}
	modelAnswer := "已确认信号与系统未通过，建议核对补考安排。"
	if got := academicRiskFinalAnswer(modelAnswer, verified, false); got != modelAnswer {
		t.Fatalf("unexpected replacement without risk result, got %q", got)
	}
}
