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
	require.Equal(t, publicOnly, routeModelTools("补考成绩怎么算", definitions))
	require.Equal(t, publicOnly, routeModelTools("GPA", definitions))
	require.Equal(t, definitions, routeModelTools("查看我的成绩", definitions))
	require.Equal(t, definitions, routeModelTools("分析成绩", definitions))
	// Hy3 不可用时，个人分析仍可降级到内置学业工具。
	require.Equal(t, definitions, routeModelTools("计算我的 GPA 和学分情况", definitions))
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
