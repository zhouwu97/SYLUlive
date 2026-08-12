package ai

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestRouteModelToolsPrefersHy3ForDecisionIntents(t *testing.T) {
	definitions := []ToolDefinition{
		{Name: "academic_resolve_context"},
		{Name: "academic_get_grade_summary"},
		{Name: "competition_search_catalog"},
		{Name: "hy3_decision_analyze_academic"},
		{Name: "hy3_decision_compare_competitions"},
		{Name: "hy3_decision_plan_student_week"},
	}
	tests := []struct {
		name     string
		message  string
		expected []string
	}{
		{
			name:     "明确 Hy3 学业分析",
			message:  "请用Hy3分析学业",
			expected: []string{"hy3_decision_analyze_academic"},
		},
		{
			name:     "校园首页学业分析入口",
			message:  "分析我的学业情况，找出主要风险并给出改进建议",
			expected: []string{"hy3_decision_analyze_academic"},
		},
		{
			name:     "GPA 和学分综合分析",
			message:  "计算我的 GPA 和学分情况",
			expected: []string{"hy3_decision_analyze_academic"},
		},
		{
			name:     "学生周计划",
			message:  "帮我安排本周运动时间",
			expected: []string{"hy3_decision_plan_student_week"},
		},
		{
			name:    "个性化竞赛比较",
			message: "数学建模和创新方法竞赛哪个更适合我",
			expected: []string{
				"competition_search_catalog",
				"hy3_decision_compare_competitions",
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			routed := routeModelTools(test.message, definitions)
			names := make([]string, 0, len(routed))
			for _, definition := range routed {
				names = append(names, definition.Name)
			}
			require.Equal(t, test.expected, names)
		})
	}
}

func TestRouteModelToolsKeepsPublicQuestionsAwayFromPersonalDataTools(t *testing.T) {
	definitions := []ToolDefinition{
		{Name: "academic_get_grade_summary"},
		{Name: "campus_search_policy"},
	}

	publicOnly := []ToolDefinition{{Name: "campus_search_policy"}}
	academicOnly := []ToolDefinition{{Name: "academic_get_grade_summary"}}
	require.Equal(t, publicOnly, routeModelTools("补考成绩怎么算", definitions))
	require.Equal(t, publicOnly, routeModelTools("GPA", definitions))
	require.Equal(t, academicOnly, routeModelTools("查看我的成绩", definitions))
	require.Equal(t, academicOnly, routeModelTools("分析成绩", definitions))
	// Hy3 不可用时，个人分析仍可降级到内置学业工具。
	require.Equal(t, academicOnly, routeModelTools("计算我的 GPA 和学分情况", definitions))
}

func TestRouteModelToolsForMessagesKeepsHy3RouteAfterConsentResume(t *testing.T) {
	definitions := []ToolDefinition{
		{Name: "academic_resolve_context"},
		{Name: "hy3_decision_analyze_academic"},
	}
	messages := []Message{
		{Role: "system", Content: "系统提示"},
		{Role: "user", Content: "用户问题：请用Hy3分析学业\n\n已核验证据："},
		{Role: "assistant", ToolCalls: []ToolCallMessage{{ID: "call_1"}}},
		{Role: "tool", ToolCallID: "call_1", Content: `{"status":"waiting"}`},
	}

	require.Equal(t, []ToolDefinition{{Name: "hy3_decision_analyze_academic"}}, routeModelToolsForMessages(messages, definitions))
}

func TestVerifiedPolicyRAGDoesNotDisablePersonalHy3Intent(t *testing.T) {
	makeupChunks := []RetrievedChunk{{ChunkID: 1, Content: "补考总成绩由原平时成绩与补考卷面成绩按课程比例合成"}}
	retakeChunks := []RetrievedChunk{{ChunkID: 2, Content: "课程重修应按规定报名"}}
	weakChunks := []RetrievedChunk{{ChunkID: 3, Content: "竞赛成绩奖励规则"}}
	require.True(t, shouldAnswerFromVerifiedRAG(BuildPolicyQueryPlan("补考成绩怎么算"), makeupChunks))
	require.True(t, shouldAnswerFromVerifiedRAG(BuildPolicyQueryPlan("重修有什么规定"), retakeChunks))
	require.False(t, shouldAnswerFromVerifiedRAG(BuildPolicyQueryPlan("补考成绩怎么算"), weakChunks))
	require.False(t, shouldAnswerFromVerifiedRAG(BuildPolicyQueryPlan("计算我的 GPA 和学分情况"), makeupChunks))
}

func TestPolicyRetrievalQueryForAcademicAnalysisTargetsFailedCourseRules(t *testing.T) {
	query := policyRetrievalQuery(
		"分析我的学业情况，找出主要风险并给出改进建议",
		"hy3_decision_analyze_academic",
	)
	require.Equal(t, "挂科了怎么办", query)
	require.Equal(t, PolicyIntentFailedCourse, BuildPolicyQueryPlan(query).Intent)
}

func TestPolicyRetrievalQueryKeepsNonAcademicQuestion(t *testing.T) {
	require.Equal(t, "奖学金有什么规定", policyRetrievalQuery("奖学金有什么规定", ""))
}

func TestCampusProcedureClaimRequiresCitation(t *testing.T) {
	require.True(t, containsCampusProcedureClaim("请关注后续补考或重修安排"))
	require.True(t, containsCampusProcedureClaim("按学院安排报名"))
	require.False(t, containsCampusProcedureClaim("信号与系统目前未通过，建议优先复习"))
}
