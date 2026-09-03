package ai

import (
	"encoding/json"
	"sort"
	"strings"
)

// AgentCapability 是面向客户端的稳定能力契约。
// 它描述“能做什么”和所需授权，不暴露 Provider、提示词或内部实现细节。
type AgentCapability struct {
	ID                   string             `json:"id"`
	Version              string             `json:"version"`
	Provider             string             `json:"provider,omitempty"`
	Lane                 string             `json:"lane"`
	Kind                 string             `json:"kind"`
	Description          string             `json:"description"`
	Available            bool               `json:"available"`
	ToolNames            []string           `json:"tool_names,omitempty"`
	Tags                 []string           `json:"tags,omitempty"`
	InputSchema          json.RawMessage    `json:"input_schema,omitempty"`
	OutputSchema         json.RawMessage    `json:"output_schema,omitempty"`
	PermissionScopes     []string           `json:"permission_scopes,omitempty"`
	RequiresConfirmation bool               `json:"requires_confirmation"`
	SideEffect           SideEffectLevel    `json:"side_effect"`
	Confirmation         ConfirmationPolicy `json:"confirmation"`
	Freshness            FreshnessClass     `json:"freshness"`
	CostClass            string             `json:"cost_class,omitempty"`
	LatencyClass         string             `json:"latency_class,omitempty"`
}

// AgentCapabilityRegistry 统一维护校园 Agent、个人 Agent 和设备桥的能力声明。
// V1 只读能力仍然以 ToolRegistry 为事实来源，行动能力则由服务端受控 API 提供。
type AgentCapabilityRegistry struct {
	toolRegistry *ToolRegistry
}

// RetrieveCapabilities 是轻量的语义候选检索器：先做权限/可用性过滤，再按描述、标签和能力 ID 的词重叠排序。
// 后续可以替换成向量检索，但 Agent 的安全过滤和 top-N 约束保持在 Go Control Plane 内。
func RetrieveCapabilities(query string, capabilities []AgentCapability, allowedScopes []string, limit int) []AgentCapability {
	if limit <= 0 || limit > 32 {
		limit = 12
	}
	queryTokens := capabilityTokens(query)
	allowed := make(map[string]struct{}, len(allowedScopes))
	for _, scope := range allowedScopes {
		allowed[strings.TrimSpace(scope)] = struct{}{}
	}
	type scored struct {
		capability AgentCapability
		score      int
	}
	scoredItems := make([]scored, 0, len(capabilities))
	for _, capability := range capabilities {
		if !capability.Available || !capabilityScopesAllowed(capability, allowed) {
			continue
		}
		searchText := strings.Join(append(append([]string{capability.ID, capability.Description}, capability.Tags...), capability.ToolNames...), " ")
		score := 0
		for _, token := range queryTokens {
			if strings.Contains(strings.ToLower(searchText), token) {
				score++
			}
		}
		// 没有词命中时仍保留公共通用能力，避免中文分词失败导致 Agent 无工具可选。
		if score > 0 || capability.Lane == "public" {
			scoredItems = append(scoredItems, scored{capability: capability, score: score})
		}
	}
	sort.SliceStable(scoredItems, func(i, j int) bool {
		if scoredItems[i].score != scoredItems[j].score {
			return scoredItems[i].score > scoredItems[j].score
		}
		return scoredItems[i].capability.ID < scoredItems[j].capability.ID
	})
	if len(scoredItems) > limit {
		scoredItems = scoredItems[:limit]
	}
	result := make([]AgentCapability, len(scoredItems))
	for index, item := range scoredItems {
		result[index] = item.capability
	}
	return result
}

func capabilityScopesAllowed(capability AgentCapability, allowed map[string]struct{}) bool {
	if len(allowed) == 0 || len(capability.PermissionScopes) == 0 {
		return true
	}
	for _, scope := range capability.PermissionScopes {
		if _, ok := allowed[scope]; ok {
			return true
		}
	}
	return false
}

func capabilityTokens(value string) []string {
	value = strings.ToLower(strings.TrimSpace(value))
	if value == "" {
		return nil
	}
	// 中英文校园领域词的最小 token 化；不会把原文写入日志或 Grant。
	known := []string{"比赛", "竞赛", "成绩", "学分", "课表", "课程", "日程", "空闲", "冲突", "规划", "计划", "政策", "通知", "食堂", "截止", "适合", "推荐", "就业", "学业", "安排"}
	result := make([]string, 0, len(known)+4)
	for _, token := range known {
		if strings.Contains(value, token) {
			result = append(result, token)
		}
	}
	for _, token := range strings.FieldsFunc(value, func(r rune) bool { return r == ' ' || r == ',' || r == '，' || r == '。' }) {
		if len([]rune(token)) >= 2 {
			result = append(result, token)
		}
	}
	return result
}

func NewAgentCapabilityRegistry(toolRegistry *ToolRegistry) *AgentCapabilityRegistry {
	return &AgentCapabilityRegistry{toolRegistry: toolRegistry}
}

func (r *AgentCapabilityRegistry) Public() []AgentCapability {
	toolAvailable := func(names ...string) bool {
		if r == nil || r.toolRegistry == nil {
			return false
		}
		for _, name := range names {
			if r.toolRegistry.HasTool(name) {
				return true
			}
		}
		return false
	}
	capabilities := []AgentCapability{
		{
			ID: "system.status", Version: AgentContractVersion, Provider: "sylulive_mcp", Lane: "public", Kind: "read",
			Description: "读取纯能力层契约和健康状态", Available: r != nil,
			Tags: []string{"状态", "健康", "系统"}, SideEffect: SideEffectNone, Confirmation: ConfirmationNever, Freshness: FreshnessStatic,
		},
		{
			ID: "policy.search", Version: AgentContractVersion, Provider: "sylulive_mcp", Lane: "public", Kind: "read",
			Description: "检索已发布的学校政策、办事规则和官方通知", Available: r != nil,
			Tags: []string{"政策", "通知", "办事", "规则"}, SideEffect: SideEffectNone, Confirmation: ConfirmationNever, Freshness: FreshnessLive,
		},
		{
			ID: "policy.sources", Version: AgentContractVersion, Provider: "sylulive_mcp", Lane: "public", Kind: "read",
			Description: "读取政策回答所需的已发布证据来源", Available: r != nil,
			Tags: []string{"政策", "来源", "证据"}, SideEffect: SideEffectNone, Confirmation: ConfirmationNever, Freshness: FreshnessLive,
		},
		{
			ID: "competition.search", Version: AgentContractVersion, Provider: "sylulive_mcp", Lane: "public", Kind: "read",
			Description: "检索公开赛事事实", Available: r != nil,
			Tags: []string{"竞赛", "比赛", "推荐", "截止"}, ToolNames: []string{"competition.search"}, SideEffect: SideEffectNone, Confirmation: ConfirmationNever, Freshness: FreshnessLive,
		},
		{
			ID: "competition.details", Version: AgentContractVersion, Provider: "sylulive_mcp", Lane: "public", Kind: "read",
			Description: "读取公开赛事详情和报名事实", Available: r != nil,
			Tags: []string{"竞赛", "比赛", "详情", "报名"}, ToolNames: []string{"competition.details"}, SideEffect: SideEffectNone, Confirmation: ConfirmationNever, Freshness: FreshnessLive,
		},
		{
			ID: "competition.governed_context", Version: AgentContractVersion, Provider: "sylulive_mcp", Lane: "public", Kind: "read",
			Description: "读取经过治理的赛事候选上下文", Available: r != nil,
			Tags: []string{"竞赛", "适合", "资格", "候选"}, ToolNames: []string{"competition.governed_context"}, SideEffect: SideEffectNone, Confirmation: ConfirmationNever, Freshness: FreshnessLive,
		},
		{
			ID: "competition.verify", Version: AgentContractVersion, Provider: "sylulive_mcp", Lane: "public", Kind: "verify",
			Description: "核对赛事记录哈希、发布状态和事实版本", Available: r != nil,
			Tags: []string{"竞赛", "核对", "验证", "版本"}, ToolNames: []string{"competition.verify"}, SideEffect: SideEffectNone, Confirmation: ConfirmationNever, Freshness: FreshnessLive,
		},
		{
			ID: "competition.compare", Version: AgentContractVersion, Provider: "sylulive_mcp", Lane: "public", Kind: "read",
			Description: "比较多个赛事的公开确定性事实", Available: r != nil,
			Tags: []string{"竞赛", "比赛", "比较", "推荐"}, ToolNames: []string{"competition.compare"}, SideEffect: SideEffectNone, Confirmation: ConfirmationNever, Freshness: FreshnessLive,
		},
		{
			ID: "academic.summary", Version: AgentContractVersion, Provider: "sylulive_mcp", Lane: "personal", Kind: "read",
			Description: "在授权后读取当前用户的学业摘要", Available: r != nil,
			Tags: []string{"成绩", "学分", "学业", "风险"}, ToolNames: []string{"academic.summary"}, PermissionScopes: []string{"ai_personal_data_access", "academic:summary"}, SideEffect: SideEffectNone, Confirmation: ConfirmationNever, Freshness: FreshnessLive,
		},
		{
			ID: "schedule.free_windows", Version: AgentContractVersion, Provider: "sylulive_mcp", Lane: "personal", Kind: "read",
			Description: "在授权后根据课程和个人日历计算空闲时间", Available: r != nil,
			Tags: []string{"课表", "课程", "空闲", "冲突", "时间"}, ToolNames: []string{"schedule.free_windows"}, PermissionScopes: []string{"ai_personal_data_access", "schedule:read"}, SideEffect: SideEffectNone, Confirmation: ConfirmationNever, Freshness: FreshnessLive,
		},
		{
			ID: "schedule.validate_plan", Version: AgentContractVersion, Provider: "sylulive_mcp", Lane: "personal", Kind: "verify",
			Description: "在授权后确定性校验计划与当前日程是否冲突", Available: r != nil,
			Tags: []string{"课表", "课程", "计划", "冲突", "安排"}, ToolNames: []string{"schedule.validate_plan"}, PermissionScopes: []string{"ai_personal_data_access", "schedule:read"}, SideEffect: SideEffectNone, Confirmation: ConfirmationNever, Freshness: FreshnessLive,
		},
		{
			ID: "campus.policy_search", Version: "1", Lane: "public", Kind: "read",
			Description: "检索学校政策、办事规则和官方通知", Available: toolAvailable("campus.search_policy", "campus.search_notifications"),
			ToolNames: []string{"campus.search_policy", "campus.search_notifications"},
		},
		{
			ID: "campus.service_search", Version: "1", Lane: "public", Kind: "read",
			Description: "检索校园服务、竞赛和考试资料", Available: toolAvailable("campus.search_service", "competition.search_catalog", "exam.search_materials"),
			ToolNames: []string{"campus.search_service", "competition.search_catalog", "exam.search_materials"},
		},
		{
			ID: "calendar.official_read", Version: "1", Lane: "public", Kind: "read",
			Description: "查询指定日期的官方校历、教学周和调休信息", Available: toolAvailable("calendar.get_day"),
			ToolNames: []string{"calendar.get_day", "calendar.get_range", "calendar.get_current_term", "calendar.get_teaching_week"},
		},
		{
			ID: "canteen.discovery", Version: "1", Lane: "public", Kind: "read",
			Description: "查询当前可用食堂和公开菜品", Available: toolAvailable("canteen.search", "canteen.get_details"),
			ToolNames: []string{"canteen.search", "canteen.get_details", "canteen.search_dishes", "canteen.get_dish_details", "canteen.get_rankings", "canteen.get_recent_reviews"},
		},
		{
			ID: "academic.personal_read", Version: "1", Lane: "personal", Kind: "read",
			Description: "在授权后读取成绩、学分、课表和学业风险摘要", Available: toolAvailable("academic.get_grade_summary", "academic.get_credit_summary", "academic.get_risk_analysis"),
			ToolNames:        []string{"academic.get_grade_summary", "academic.get_credit_summary", "academic.get_risk_analysis"},
			PermissionScopes: []string{"ai_personal_data_access", "academic_cloud_storage"},
		},
		{
			ID: "academic.personal_refresh", Version: "1", Lane: "device", Kind: "refresh",
			Description: "在授权后从设备侧刷新教务数据", Available: toolAvailable("academic.get_grade_summary", "academic.get_credit_summary"),
			ToolNames:        []string{"device.academic.ensure_fresh_grade_summary", "device.academic.ensure_fresh_risk_context", "device.academic.ensure_fresh_bundle", "device.schedule.ensure_fresh_week", "device.academic.ensure_fresh_credit_summary"},
			PermissionScopes: []string{"ai_personal_data_access", "ai_device_cache_access", "ai_remote_edu_refresh"},
		},
		{
			ID: "competition.plan_add", Version: "1", Lane: "personal", Kind: "action",
			Description: "把已核验竞赛加入个人计划日历", Available: true,
			RequiresConfirmation: true,
		},
		{
			ID: "competition.personal_read", Version: "1", Lane: "personal", Kind: "read",
			Description: "读取当前用户自己的竞赛计划、报名截止时间和计划日历", Available: toolAvailable("competition.get_my_plan", "competition.get_deadlines", "competition.get_calendar"),
			ToolNames:        []string{"competition.get_my_plan", "competition.get_deadlines", "competition.get_calendar"},
			PermissionScopes: []string{"ai_personal_data_access"},
		},
		{
			ID: "calendar.event_manage", Version: "1", Lane: "personal", Kind: "action",
			Description: "创建、修改或删除个人日历事件", Available: true,
			ToolNames:            []string{"calendar.propose_action", "draft_calendar_action"},
			RequiresConfirmation: true,
		},
		{
			ID: "calendar.reminder_manage", Version: "1", Lane: "personal", Kind: "action",
			Description: "为个人日历事件设置提醒", Available: true,
			ToolNames:            []string{"calendar.propose_action", "draft_calendar_action"},
			RequiresConfirmation: true,
		},
		{
			ID: "personal_calendar.read", Version: "1", Lane: "personal", Kind: "read",
			Description: "读取当前用户自己的个人日历并计算可用时间窗口", Available: toolAvailable("personal_calendar.get_events", "personal_calendar.get_range", "personal_calendar.get_day", "personal_calendar.find_free_time"),
			ToolNames:        []string{"personal_calendar.get_events", "personal_calendar.get_range", "personal_calendar.get_day", "personal_calendar.find_free_time"},
			PermissionScopes: []string{"ai_personal_data_access"},
		},
	}
	sort.Slice(capabilities, func(i, j int) bool { return capabilities[i].ID < capabilities[j].ID })
	return capabilities
}
