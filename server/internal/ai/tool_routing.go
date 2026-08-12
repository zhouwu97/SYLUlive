package ai

import "strings"

const (
	modelToolHy3Academic    = "hy3_decision_analyze_academic"
	modelToolHy3Competition = "hy3_decision_compare_competitions"
	modelToolHy3WeekPlan    = "hy3_decision_plan_student_week"
	modelToolCompetition    = "competition_search_catalog"
)

// routeModelTools 根据用户意图缩小模型可见工具集合。
// Hy3 能力缺失时只暴露同领域的普通校园工具，避免模型跨领域乱选工具。
func routeModelTools(message string, definitions []ToolDefinition) []ToolDefinition {
	targets, requiredHy3 := hy3RouteTargets(message)
	if len(targets) == 0 {
		if isPersonalToolIntent(message) {
			if containsAny(strings.ToLower(message), "学业", "成绩", "gpa", "绩点", "学分", "挂科") {
				return academicToolDefinitions(definitions)
			}
			return definitions
		}
		return publicToolDefinitions(definitions)
	}
	available := make(map[string]struct{}, len(definitions))
	for _, definition := range definitions {
		available[definition.Name] = struct{}{}
	}
	if _, found := available[requiredHy3]; !found {
		if containsAny(strings.ToLower(message), "学业", "成绩", "gpa", "绩点", "学分", "挂科") {
			return academicToolDefinitions(definitions)
		}
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

// requiredDecisionTool 将明确的个人决策意图转换为服务端完成条件。
// 返回的名称使用模型可见别名，与 ToolDefinition.Name 保持一致。
func requiredDecisionTool(message string, definitions []ToolDefinition) (string, bool) {
	_, required := hy3RouteTargets(message)
	if required == "" {
		return "", false
	}
	for _, definition := range definitions {
		if definition.Name == required {
			return required, true
		}
	}
	// Hy3 未注册时 routeModelTools 会保留内置学业工具降级路径；
	// 这些工具的选择依赖具体数据集，不能强制成不存在的 Hy3 名称。
	return "", false
}

func requiredDecisionToolForMessages(messages []Message, definitions []ToolDefinition) (string, bool) {
	for index := len(messages) - 1; index >= 0; index-- {
		if messages[index].Role == "user" {
			return requiredDecisionTool(messages[index].Content, definitions)
		}
	}
	return "", false
}

// shouldRetrievePolicyForDecision 仅让明确同时询问校规的个人问题进入双依赖路径。
// 单纯学业分析和周计划不应被弱相关政策资料污染。
func shouldRetrievePolicyForDecision(message, requiredTool string) bool {
	if requiredTool == "" {
		return true
	}
	normalized := strings.ToLower(strings.TrimSpace(message))
	return containsAny(normalized,
		"规定", "政策", "办法", "申请条件", "能否申请", "是否可以申请",
		"奖学金", "评奖", "转专业", "学位授予", "毕业条件")
}

// policyRetrievalQuery 为个人学业风险分析补充固定的校规检索语义。
// 用户原问题仍原样进入生成提示；这里只让 Retriever 命中挂科后续处理的正式依据。
func policyRetrievalQuery(message, requiredTool string) string {
	message = strings.TrimSpace(message)
	if requiredTool == "hy3_decision_analyze_academic" {
		return "挂科了怎么办"
	}
	if shouldRetrievePolicyForDecision(message, requiredTool) {
		return message
	}
	return ""
}

func academicToolDefinitions(definitions []ToolDefinition) []ToolDefinition {
	selected := make([]ToolDefinition, 0, len(definitions))
	for _, definition := range definitions {
		if strings.HasPrefix(definition.Name, "academic_") || strings.HasPrefix(definition.Name, "schedule_") {
			selected = append(selected, definition)
		}
	}
	if len(selected) == 0 {
		return definitions
	}
	return selected
}

// publicToolDefinitions 禁止普通校园问答误读个人成绩、课表或画像。
// 个人数据工具只有在问题明确指向当前用户或要求执行个人查询时才对模型可见。
func publicToolDefinitions(definitions []ToolDefinition) []ToolDefinition {
	selected := make([]ToolDefinition, 0, len(definitions))
	for _, definition := range definitions {
		if isPersonalModelTool(definition.Name) {
			continue
		}
		selected = append(selected, definition)
	}
	return selected
}

func isPersonalModelTool(name string) bool {
	return strings.HasPrefix(name, "academic_") ||
		strings.HasPrefix(name, "schedule_") ||
		strings.HasPrefix(name, "erke_") ||
		strings.HasPrefix(name, "profile_") ||
		strings.HasPrefix(name, "hy3_decision_")
}

func isPersonalToolIntent(message string) bool {
	normalized := strings.ToLower(strings.TrimSpace(message))
	if normalized == "" {
		return false
	}
	if containsAny(normalized, "我的", "帮我", "给我", "为我", "本人", "个人") {
		return true
	}
	academicTopic := containsAny(normalized, "学业", "成绩", "gpa", "绩点", "学分", "挂科")
	personalAction := containsAny(normalized, "查看", "查询", "分析", "计算", "统计", "刷新")
	if academicTopic && personalAction {
		return true
	}
	// 课表和空闲时间天然依赖当前用户，即使省略“我的”也属于个人查询。
	return containsAny(normalized, "有课吗", "空闲", "课表", "课程安排")
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
	// 校园首页使用“分析我的学业情况，找出主要风险并给出改进建议”等自然语言，
	// 不一定出现连续的“学业分析”，但仍然明确要求基于个人学业数据做判断。
	comprehensiveAcademic = comprehensiveAcademic ||
		(hasAcademicTopic && containsAny(normalized, "分析", "风险", "改进建议"))
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
