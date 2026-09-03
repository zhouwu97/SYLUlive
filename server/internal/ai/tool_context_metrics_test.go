package ai

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMeasureToolContextQuantifiesScopedDeterministicRoutes(t *testing.T) {
	definitions := toolContextFixtureDefinitions()
	baseline := MeasureToolContext(definitions, definitions, "all_registered", false)
	require.True(t, baseline.SchemaMeasurementAvailable)
	require.Equal(t, len(definitions), baseline.RegisteredToolCount)
	require.Equal(t, len(definitions), baseline.ModelVisibleToolCount)
	require.Positive(t, baseline.SchemaBytes)
	require.Positive(t, baseline.SchemaTokenEstimate)

	cases := []struct {
		name    string
		message string
		want    []string
	}{
		{
			name:    "公共政策问答不携带个人工具",
			message: "补考成绩怎么算",
			want:    []string{"campus_search_policy", "calendar_get_day", "canteen_search", "competition_search_catalog"},
		},
		{
			name:    "个人学业分析只保留确定性入口",
			message: "分析我的学业情况，找出主要风险并给出改进建议",
			want:    []string{"academic_get_risk_analysis"},
		},
		{
			name:    "课表空闲时间只保留课表入口",
			message: "这周哪几天下午比较空？",
			want:    []string{"schedule_get_availability"},
		},
		{
			name:    "个人竞赛计划只保留计划入口",
			message: "请分析我的竞赛计划和截止时间",
			want:    []string{"competition_get_my_plan"},
		},
	}

	totalVisible := 0
	totalTokenEstimate := 0
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			visible := routeModelTools(testCase.message, definitions)
			metrics := MeasureToolContext(
				definitions,
				visible,
				toolContextRoutingLegacyDeterministic,
				false,
			)
			got := make([]string, 0, len(visible))
			for _, definition := range visible {
				got = append(got, definition.Name)
			}
			require.Equal(t, testCase.want, got)
			require.LessOrEqual(t, metrics.ModelVisibleToolCount, baseline.ModelVisibleToolCount)
			require.LessOrEqual(t, metrics.SchemaTokenEstimate, baseline.SchemaTokenEstimate)
			if testCase.name == "公共政策问答不携带个人工具" {
				for _, definition := range visible {
					require.False(t, isPersonalModelTool(definition.Name))
				}
			}
			totalVisible += metrics.ModelVisibleToolCount
			totalTokenEstimate += metrics.SchemaTokenEstimate
		})
	}

	require.Less(t, totalVisible, baseline.ModelVisibleToolCount*len(cases))
	require.Less(t, totalTokenEstimate, baseline.SchemaTokenEstimate*len(cases))
	t.Logf(
		"fixture_tool_context baseline_tools=%d baseline_schema_token_estimate=%d average_visible_tools=%.2f average_schema_token_estimate=%.2f",
		baseline.ModelVisibleToolCount,
		baseline.SchemaTokenEstimate,
		float64(totalVisible)/float64(len(cases)),
		float64(totalTokenEstimate)/float64(len(cases)),
	)
}

func TestToolContextMetricsAreTraceSafeAndAggregated(t *testing.T) {
	metrics := MeasureToolContext(
		toolContextFixtureDefinitions(),
		[]ToolDefinition{{Name: "campus_search_policy", Description: "检索已发布校园政策", Parameters: map[string]interface{}{"type": "object"}}},
		toolContextRoutingUnifiedShortlist,
		false,
	)
	encoded, err := marshalEventPayload("retrieval.completed", map[string]interface{}{
		"registered_tool_count":             metrics.RegisteredToolCount,
		"model_visible_tool_count":          metrics.ModelVisibleToolCount,
		"tool_schema_bytes":                 metrics.SchemaBytes,
		"tool_schema_token_estimate":        metrics.SchemaTokenEstimate,
		"tool_schema_measurement_available": metrics.SchemaMeasurementAvailable,
		"token":                             "should-not-persist",
		"schema":                            "工具 Schema 原文不应进入事件",
	}, true)
	require.NoError(t, err)
	require.NotContains(t, string(encoded), "检索已发布校园政策")
	require.NotContains(t, string(encoded), "parameters")
	require.Contains(t, string(encoded), "tool_schema_token_estimate")
	require.NotContains(t, string(encoded), "should-not-persist")

	var trace AgentTraceMetrics
	trace.Observe("retrieval.completed", encoded)
	require.Equal(t, 1, trace.ToolContextSamples)
	require.Equal(t, metrics.RegisteredToolCount, trace.RegisteredToolCount)
	require.Equal(t, metrics.ModelVisibleToolCount, trace.ModelVisibleToolCount)
	require.Equal(t, metrics.SchemaBytes, trace.ToolSchemaBytes)
	require.Equal(t, metrics.SchemaTokenEstimate, trace.ToolSchemaTokenEstimate)
}

func TestMeasureToolContextMarksVerifiedPolicySuppression(t *testing.T) {
	metrics := MeasureToolContext(
		toolContextFixtureDefinitions(),
		nil,
		toolContextRoutingNoToolsForPolicyRAG,
		true,
	)
	require.True(t, metrics.SuppressedByVerifiedPolicyRAG)
	require.Zero(t, metrics.ModelVisibleToolCount)
	require.True(t, metrics.SchemaMeasurementAvailable)
	require.Zero(t, metrics.SchemaBytes)
	require.Zero(t, metrics.SchemaTokenEstimate)
}

func TestTraceMetricsCountExplicitZeroToolSample(t *testing.T) {
	metrics := MeasureToolContext(nil, nil, toolContextRoutingNoToolsForPolicyRAG, true)
	payload, err := json.Marshal(metrics)
	require.NoError(t, err)

	var trace AgentTraceMetrics
	trace.Observe("retrieval.completed", payload)
	require.Equal(t, 1, trace.ToolContextSamples)
	require.Zero(t, trace.RegisteredToolCount)
	require.Zero(t, trace.ModelVisibleToolCount)
}

func toolContextFixtureDefinitions() []ToolDefinition {
	return []ToolDefinition{
		{Name: "campus_search_policy", Description: "检索已发布校园政策、办事规则和官方通知", Parameters: map[string]interface{}{"type": "object", "properties": map[string]interface{}{"query": map[string]interface{}{"type": "string"}}}},
		{Name: "calendar_get_day", Description: "读取公开校历和教学周", Parameters: map[string]interface{}{"type": "object", "properties": map[string]interface{}{"date": map[string]interface{}{"type": "string"}}}},
		{Name: "canteen_search", Description: "查询公开食堂档口和营业状态", Parameters: map[string]interface{}{"type": "object", "properties": map[string]interface{}{"campus": map[string]interface{}{"type": "string"}}}},
		{Name: "competition_search_catalog", Description: "检索公开竞赛目录和报名截止时间", Parameters: map[string]interface{}{"type": "object", "properties": map[string]interface{}{"keyword": map[string]interface{}{"type": "string"}}}},
		{Name: "academic_get_grade_summary", Description: "读取当前用户的成绩和学分摘要", Parameters: map[string]interface{}{"type": "object"}},
		{Name: "academic_get_risk_analysis", Description: "计算当前用户的学业风险和改进建议", Parameters: map[string]interface{}{"type": "object"}},
		{Name: "schedule_get_availability", Description: "读取当前用户的课表空闲时间", Parameters: map[string]interface{}{"type": "object"}},
		{Name: "competition_get_my_plan", Description: "读取当前用户的竞赛计划和截止时间", Parameters: map[string]interface{}{"type": "object"}},
	}
}
