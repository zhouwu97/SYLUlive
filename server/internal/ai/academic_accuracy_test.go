package ai

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"shenliyuan/internal/academic"
)

func TestAcademicRiskExpiredCreditSnapshotsAreNotMissing(t *testing.T) {
	fetched := time.Now().Add(-48 * time.Hour)
	results := map[academic.DatasetType]academic.ContextResult{
		academic.DatasetGrades:             {Status: academic.DataStatusAvailable, Data: json.RawMessage(`{"grades":[{"course_name":"数学","credits":3,"fraction":80}]}`)},
		academic.DatasetCreditRequirements: {Status: academic.DataStatusNeedsRefresh, IsStale: true, FetchedAt: &fetched, Data: json.RawMessage(`{"required_credits":160,"earned_credits":80}`)},
		academic.DatasetAcademicSituation:  {Status: academic.DataStatusNeedsRefresh, IsStale: true, FetchedAt: &fetched},
		academic.DatasetErke:               {Status: academic.DataStatusMissing, Warnings: []string{"没有已授权上传的二课快照；请在手机更新二课后选择上传"}},
	}
	data, warnings := buildAcademicRiskAnalysis(results, academicRiskCoreDatasets())
	require.NotContains(t, strings.Join(data["to_confirm"].([]string), "；"), "快照缺失")
	require.NotContains(t, data, "credits", "过期数据不能悄悄参与实时学分核算")
	raw, err := json.Marshal(aggregatePersonalToolResult(data, results, warnings))
	require.NoError(t, err)
	answer, riskSeen := academicRiskFallback("academic.get_risk_analysis", raw)
	require.True(t, riskSeen)
	for _, expected := range []string{"1 门课程", "这些成绩记录中未发现未通过课程", "毕业学分是否达标：暂不能判断", "学分要求数据为2天前同步", "请在手机更新并同步学分要求、学业情况", "数据说明：\n\n- "} {
		require.Contains(t, answer, expected)
	}
	require.NotContains(t, answer, "快照缺失")
	require.NotContains(t, answer, "已同步，但需更新", "数据年龄说明已覆盖同义确认项")
	require.Equal(t, 2, strings.Count(answer, "二课"))
}

func TestAcademicCreditModuleGapsDoNotOffsetOrAssumeMissingIsZero(t *testing.T) {
	for _, tc := range []struct {
		name, raw         string
		gap               float64
		known, incomplete bool
	}{
		{"separate modules", `{"modules":[{"required_credits":10,"earned_credits":20},{"required_credits":10,"earned_credits":5}]}`, 5, true, false},
		{"unknown requirement", `{"modules":[{"required_credits":null,"earned_credits":5}]}`, 0, false, true},
		{"partly unknown", `{"modules":[{"required_credits":10,"earned_credits":10},{"earned_credits":5}]}`, 0, false, true},
		{"empty modules override flat totals", `{"credit_gap":0,"required_credits":10,"earned_credits":10,"modules":[]}`, 0, false, true},
		{"verified zero", `{"modules":[{"required_credits":10,"earned_credits":10}]}`, 0, true, false},
		{"legacy explicit gap", `{"credit_gap":5}`, 5, true, false},
		{"success alone", `{"success":true}`, 0, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			credit := extractCreditFields(json.RawMessage(tc.raw))
			gap, known := academicCreditGap(credit)
			require.Equal(t, tc.known, known)
			require.Equal(t, tc.gap, gap)
			require.Equal(t, tc.incomplete, credit["requirements_incomplete"] == true)
		})
	}
}

func TestAcademicRiskUnreadableDataDoesNotClaimPassedOrNoCreditGap(t *testing.T) {
	for _, status := range []academic.DataStatus{academic.DataStatusMissing, academic.DataStatusPermissionRequired, academic.DataStatusCorrupted} {
		t.Run(string(status), func(t *testing.T) {
			results := map[academic.DatasetType]academic.ContextResult{}
			for _, dataset := range academicRiskCoreDatasets() {
				results[dataset] = academic.ContextResult{Status: status}
			}
			data, warnings := buildAcademicRiskAnalysis(results, academicRiskCoreDatasets())
			raw, err := json.Marshal(aggregatePersonalToolResult(data, results, warnings))
			require.NoError(t, err)
			answer, _ := academicRiskFallback("academic.get_risk_analysis", raw)
			require.NotContains(t, answer, "未发现未通过课程")
			require.NotContains(t, answer, "学分未见缺口")
			if status != academic.DataStatusMissing {
				require.NotContains(t, answer, "快照缺失")
			}
		})
	}
}

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
