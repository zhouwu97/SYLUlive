package ai

import "strings"

const (
	modelToolHy3Competition    = "hy3_decision_compare_competitions"
	modelToolHy3CompetitionFit = "hy3_decision_explain_competition_candidates"
	modelToolHy3WeekPlan       = "hy3_decision_plan_student_week"
	modelToolCompetition       = "competition_search_catalog"
	modelToolCompetitionPlan   = "competition_get_my_plan"
	modelToolAcademicRisk      = "academic_get_risk_analysis"
	modelToolSchedule          = "schedule_get_availability"
)

// shortlistModelTools 使用 Capability Registry 做第一轮语义召回，避免把整张工具表
// 直接暴露给模型。个人能力仍由后续 subject/grant 校验决定，不能通过检索绕过权限。
func shortlistModelTools(message string, definitions []ToolDefinition) []ToolDefinition {
	if len(definitions) == 0 {
		return nil
	}
	sourceDefinitions := definitions
	personal := isPersonalToolIntent(message)
	if !personal {
		sourceDefinitions = publicToolDefinitions(definitions)
	}
	allowed := make([]AgentCapability, 0, len(sourceDefinitions))
	for _, definition := range sourceDefinitions {
		allowed = append(allowed, AgentCapability{
			ID:          definition.Name,
			Version:     AgentContractVersion,
			Description: definition.Description,
			// sourceDefinitions 已先完成公开/个人边界过滤；这里保留 public
			// fallback，让个人问题仍可同时看到不直接命中的公共事实工具。
			Lane:      "public",
			Available: true,
		})
	}
	matched := RetrieveCapabilities(message, allowed, nil, 12)
	if len(matched) == 0 {
		if personal {
			return definitions
		}
		return publicToolDefinitions(definitions)
	}
	matchedNames := make(map[string]struct{}, len(matched))
	for _, capability := range matched {
		matchedNames[capability.ID] = struct{}{}
	}
	selected := make([]ToolDefinition, 0, len(matchedNames))
	for _, definition := range sourceDefinitions {
		if _, ok := matchedNames[definition.Name]; ok {
			selected = append(selected, definition)
		}
	}
	return selected
}

// requiredFastPathTool 只保留确定性、低歧义的硬约束入口；复杂请求交给模型在
// shortlist 后自主规划，避免把旧路由器变成第二套隐式 Agent。
func requiredFastPathTool(message string, definitions []ToolDefinition) (string, bool) {
	if isScheduleAvailabilityIntent(message) {
		for _, definition := range definitions {
			if definition.Name == modelToolSchedule {
				return definition.Name, true
			}
		}
	}
	return "", false
}

// routeModelTools 根据用户意图缩小模型可见工具集合。
// Hy3 能力缺失时只暴露同领域的普通校园工具，避免模型跨领域乱选工具。
func routeModelTools(message string, definitions []ToolDefinition) []ToolDefinition {
	// 综合学业分析统一走服务端确定性学业工具，再由当前主模型生成叙事；
	// 不再把个人成绩交给 Hy3 决策工具。
	if isComprehensiveAcademicIntent(message) {
		if selected := academicAnalysisToolDefinitions(definitions); len(selected) > 0 {
			return selected
		}
		return academicToolDefinitions(definitions)
	}
	if isScheduleAvailabilityIntent(message) {
		if selected := scheduleAvailabilityToolDefinitions(definitions); len(selected) > 0 {
			return selected
		}
		return definitions
	}
	if isPersonalCompetitionPlanIntent(message) {
		if selected := competitionPlanToolDefinitions(definitions); len(selected) > 0 {
			return selected
		}
	}
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
	if isComprehensiveAcademicIntent(message) {
		for _, definition := range definitions {
			if definition.Name == modelToolAcademicRisk {
				return modelToolAcademicRisk, true
			}
		}
		// 旧注册表未包含内置综合工具时保留兼容性；生产注册表始终优先走上面的统一入口。
		for _, definition := range definitions {
			if definition.Name == "hy3_decision_analyze_academic" {
				return definition.Name, true
			}
		}
		return "", false
	}
	if isScheduleAvailabilityIntent(message) {
		for _, definition := range definitions {
			if definition.Name == modelToolSchedule {
				return modelToolSchedule, true
			}
		}
		return "", false
	}
	if isPersonalCompetitionPlanIntent(message) {
		for _, definition := range definitions {
			if definition.Name == modelToolCompetitionPlan {
				return modelToolCompetitionPlan, true
			}
		}
	}
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
	if isComprehensiveAcademicIntent(message) && requiredTool == modelToolAcademicRisk {
		// 学业风险分析只需要个人数据事实；除非用户明确问校规，
		// 不把政策召回混入模型上下文，避免建议被校规模板污染。
		return ""
	}
	if isComprehensiveAcademicIntent(message) && requiredTool == "hy3_decision_analyze_academic" {
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

func academicAnalysisToolDefinitions(definitions []ToolDefinition) []ToolDefinition {
	selected := make([]ToolDefinition, 0, 1)
	for _, definition := range definitions {
		if definition.Name == modelToolAcademicRisk {
			selected = append(selected, definition)
		}
	}
	return selected
}

func scheduleAvailabilityToolDefinitions(definitions []ToolDefinition) []ToolDefinition {
	selected := make([]ToolDefinition, 0, 1)
	for _, definition := range definitions {
		if definition.Name == modelToolSchedule {
			selected = append(selected, definition)
		}
	}
	return selected
}

func competitionPlanToolDefinitions(definitions []ToolDefinition) []ToolDefinition {
	selected := make([]ToolDefinition, 0, 1)
	for _, definition := range definitions {
		if definition.Name == modelToolCompetitionPlan {
			selected = append(selected, definition)
		}
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

// isScheduleAvailabilityIntent 识别必须依赖当前用户课表才能回答的空闲时间问题。
// 这类问题不能只把 schedule 工具“展示”给模型，否则模型可能直接用政策检索结果作答。
func isScheduleAvailabilityIntent(message string) bool {
	normalized := strings.ToLower(strings.TrimSpace(message))
	if normalized == "" {
		return false
	}
	if containsAny(normalized, "空闲", "有空", "比较空", "空余", "空档", "没课", "无课") {
		return containsAny(normalized,
			"本周", "这周", "下周", "今天", "明天", "上午", "下午", "晚上", "时间", "哪天", "星期",
			"周一", "周二", "周三", "周四", "周五", "周六", "周日")
	}
	return isPersonalToolIntent(normalized) &&
		containsAny(normalized, "课表", "课程", "日程", "安排") &&
		containsAny(normalized, "分析", "评估", "规划", "建议")
}

func isPersonalCompetitionPlanIntent(message string) bool {
	normalized := strings.ToLower(strings.TrimSpace(message))
	return containsAny(normalized, "竞赛", "比赛") &&
		containsAny(normalized, "我的", "个人", "计划", "安排", "截止", "进度") &&
		containsAny(normalized, "分析", "查看", "总结", "规划", "建议", "提醒", "安排")
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
	competitionSuitability := containsAny(normalized, "适合我", "推荐我", "匹配我", "适合参加")
	if competitionTopic && competitionSuitability {
		return map[string]struct{}{modelToolHy3CompetitionFit: {}}, modelToolHy3CompetitionFit
	}
	return nil, ""
}

func isComprehensiveAcademicIntent(message string) bool {
	normalized := strings.ToLower(strings.TrimSpace(message))
	if normalized == "" {
		return false
	}
	hasAcademicTopic := containsAny(normalized, "学业", "成绩", "gpa", "绩点", "学分", "挂科")
	if !hasAcademicTopic {
		return false
	}
	return (strings.Contains(normalized, "hy3") && hasAcademicTopic) ||
		containsAny(normalized, "综合分析", "学业分析", "分析学业", "学业评估") ||
		(strings.Contains(normalized, "gpa") && strings.Contains(normalized, "学分")) ||
		(containsAny(normalized, "风险", "改进建议") && containsAny(normalized, "分析", "找出", "判断")) ||
		containsAny(normalized, "分析", "评估", "判断")
}

func containsAny(value string, candidates ...string) bool {
	for _, candidate := range candidates {
		if strings.Contains(value, candidate) {
			return true
		}
	}
	return false
}
