package ai

import "strings"

const (
	modelToolHy3Academic    = "hy3_decision_analyze_academic"
	modelToolHy3Competition = "hy3_decision_compare_competitions"
	modelToolHy3WeekPlan    = "hy3_decision_plan_student_week"
	modelToolCompetition    = "competition_search_catalog"
)

// routeModelTools 根据用户意图缩小模型可见工具集合。
// Hy3 能力缺失时保留完整工具集，由普通校园工具提供降级回答。
func routeModelTools(message string, definitions []ToolDefinition) []ToolDefinition {
	targets, requiredHy3 := hy3RouteTargets(message)
	if len(targets) == 0 {
		return definitions
	}
	available := make(map[string]struct{}, len(definitions))
	for _, definition := range definitions {
		available[definition.Name] = struct{}{}
	}
	if _, found := available[requiredHy3]; !found {
		return definitions
	}
	selected := make([]ToolDefinition, 0, len(targets))
	for _, definition := range definitions {
		if _, include := targets[definition.Name]; include {
			selected = append(selected, definition)
		}
	}
	return selected
}

func routeModelToolsForMessages(messages []Message, definitions []ToolDefinition) []ToolDefinition {
	for index := len(messages) - 1; index >= 0; index-- {
		if messages[index].Role == "user" {
			return routeModelTools(messages[index].Content, definitions)
		}
	}
	return definitions
}

func hy3RouteTargets(message string) (map[string]struct{}, string) {
	normalized := strings.ToLower(strings.TrimSpace(message))
	if normalized == "" {
		return nil, ""
	}
	hasAcademicTopic := containsAny(normalized, "学业", "成绩", "gpa", "绩点", "学分", "挂科")
	explicitHy3Academic := strings.Contains(normalized, "hy3") && hasAcademicTopic
	comprehensiveAcademic := containsAny(normalized, "综合分析", "学业分析", "分析学业", "学业评估") ||
		(strings.Contains(normalized, "gpa") && strings.Contains(normalized, "学分"))
	if explicitHy3Academic || comprehensiveAcademic {
		return map[string]struct{}{modelToolHy3Academic: {}}, modelToolHy3Academic
	}

	weekPlan := strings.Contains(normalized, "周计划") ||
		strings.Contains(normalized, "运动计划") ||
		(strings.Contains(normalized, "本周") && containsAny(normalized, "安排", "计划"))
	if weekPlan {
		return map[string]struct{}{modelToolHy3WeekPlan: {}}, modelToolHy3WeekPlan
	}

	competitionTopic := containsAny(normalized, "竞赛", "比赛")
	competitionComparison := containsAny(normalized, "比较", "对比", "哪个更适合", "哪项更适合")
	if competitionTopic && competitionComparison {
		return map[string]struct{}{
			modelToolCompetition:    {},
			modelToolHy3Competition: {},
		}, modelToolHy3Competition
	}
	return nil, ""
}

func containsAny(value string, candidates ...string) bool {
	for _, candidate := range candidates {
		if strings.Contains(value, candidate) {
			return true
		}
	}
	return false
}
