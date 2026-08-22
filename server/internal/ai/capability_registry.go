package ai

import (
	"sort"
)

// AgentCapability 是面向客户端的稳定能力契约。
// 它描述“能做什么”和所需授权，不暴露 Provider、提示词或内部实现细节。
type AgentCapability struct {
	ID                   string   `json:"id"`
	Version              string   `json:"version"`
	Lane                 string   `json:"lane"`
	Kind                 string   `json:"kind"`
	Description          string   `json:"description"`
	Available            bool     `json:"available"`
	ToolNames            []string `json:"tool_names,omitempty"`
	PermissionScopes     []string `json:"permission_scopes,omitempty"`
	RequiresConfirmation bool     `json:"requires_confirmation"`
}

// AgentCapabilityRegistry 统一维护校园 Agent、个人 Agent 和设备桥的能力声明。
// V1 只读能力仍然以 ToolRegistry 为事实来源，行动能力则由服务端受控 API 提供。
type AgentCapabilityRegistry struct {
	toolRegistry *ToolRegistry
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
			ToolNames: []string{"calendar.get_day"},
		},
		{
			ID: "canteen.discovery", Version: "1", Lane: "public", Kind: "read",
			Description: "查询当前可用食堂和公开菜品", Available: toolAvailable("canteen.search", "canteen.get_details"),
			ToolNames: []string{"canteen.search", "canteen.get_details"},
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
			ToolNames:        []string{"device.academic.ensure_fresh_overview", "device.schedule.ensure_fresh_week", "device.academic.ensure_fresh_credit_summary"},
			PermissionScopes: []string{"ai_personal_data_access", "ai_device_cache_access", "ai_remote_edu_refresh"},
		},
		{
			ID: "competition.plan_add", Version: "1", Lane: "personal", Kind: "action",
			Description: "把已核验竞赛加入个人计划日历", Available: true,
			RequiresConfirmation: true,
		},
		{
			ID: "calendar.event_manage", Version: "1", Lane: "personal", Kind: "action",
			Description: "创建、修改或删除个人日历事件", Available: true,
			RequiresConfirmation: true,
		},
		{
			ID: "calendar.reminder_manage", Version: "1", Lane: "personal", Kind: "action",
			Description: "为个人日历事件设置提醒", Available: true,
			RequiresConfirmation: true,
		},
	}
	sort.Slice(capabilities, func(i, j int) bool { return capabilities[i].ID < capabilities[j].ID })
	return capabilities
}
