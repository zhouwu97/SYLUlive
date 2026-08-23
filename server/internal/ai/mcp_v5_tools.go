package ai

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type mcpV5ToolConfig struct {
	permissions PersonalDataPermissionReader
	db          *gorm.DB
	now         func() time.Time
}

// MCPV5ToolOption 配置 v5 适配工具的服务端权限依赖。
type MCPV5ToolOption func(*mcpV5ToolConfig)

// WithMCPV5PersonalDataPermissionReader 接入与校园 MCP 相同的长期权限策略。
func WithMCPV5PersonalDataPermissionReader(reader PersonalDataPermissionReader) MCPV5ToolOption {
	return func(config *mcpV5ToolConfig) { config.permissions = reader }
}

// WithMCPV5PermissionDB 接入当前 Run 的一次性同意记录。
func WithMCPV5PermissionDB(db *gorm.DB) MCPV5ToolOption {
	return func(config *mcpV5ToolConfig) { config.db = db }
}

// WithMCPV5Clock 仅用于测试确定性地检查同意有效期。
func WithMCPV5Clock(now func() time.Time) MCPV5ToolOption {
	return func(config *mcpV5ToolConfig) { config.now = now }
}

// NewMCPV5Tools 将纯能力 MCP 映射为现有 ToolRegistry 的只读工具。
// 每个调用创建只允许调用一次的 Grant；这样即使工具执行失败，也不会把权限 token 留给下一次调用。
func NewMCPV5Tools(gateway *MCPV5Gateway, grants *ScopedGrantManager, options ...MCPV5ToolOption) []PureReadTool {
	if gateway == nil || grants == nil {
		return nil
	}
	config := &mcpV5ToolConfig{now: time.Now}
	for _, option := range options {
		if option != nil {
			option(config)
		}
	}
	definitions := []struct {
		name        string
		description string
		scopes      []string
	}{
		{"system.status", "读取纯能力层契约和健康状态", nil},
		{"policy.search", "检索已发布的学校政策、办事规则和官方通知", nil},
		{"policy.sources", "读取政策回答所需的已发布证据来源", nil},
		{"competition.search", "检索公开赛事事实", nil},
		{"competition.details", "读取公开赛事详情和报名事实", nil},
		{"competition.governed_context", "读取经过治理的赛事候选上下文", nil},
		{"competition.verify", "核对赛事记录哈希、发布状态和事实版本", nil},
		{"competition.compare", "比较多个赛事的公开确定性事实", nil},
		{"academic.summary", "在授权后读取当前用户的学业摘要", []string{"academic:summary"}},
		{"schedule.free_windows", "在授权后根据课程和个人日历计算空闲时间", []string{"schedule:read"}},
		{"schedule.validate_plan", "在授权后确定性校验计划与当前日程是否冲突", []string{"schedule:read"}},
	}
	tools := make([]PureReadTool, 0, len(definitions))
	for _, definition := range definitions {
		tools = append(tools, &mcpV5Tool{
			gateway: gateway, grants: grants, name: definition.name, description: definition.description,
			scopes: definition.scopes, permissions: config.permissions, db: config.db, now: config.now,
		})
	}
	return tools
}

type mcpV5Tool struct {
	gateway     *MCPV5Gateway
	grants      *ScopedGrantManager
	name        string
	description string
	scopes      []string
	permissions PersonalDataPermissionReader
	db          *gorm.DB
	now         func() time.Time
}

func (t *mcpV5Tool) Name() string    { return t.name }
func (t *mcpV5Tool) Version() string { return AgentContractVersion }
func (t *mcpV5Tool) Definition() ToolDefinition {
	return ToolDefinition{Name: t.name, Description: t.description, Parameters: map[string]interface{}{"type": "object"}}
}

func (t *mcpV5Tool) Execute(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	call, ok := currentToolCallContext(ctx)
	if !ok || call.UserID != userID {
		return nil, errors.New("mcp_v5_tool_context_required")
	}
	if len(t.scopes) > 0 {
		permissionMCP := &campusMCP{db: t.db, permissions: t.permissions, now: t.now}
		wait, denied, err := permissionMCP.requirePermission(ctx, userID, models.AIUserPermissionPersonalDataAccess, "读取个人学业或日程数据")
		if err != nil {
			return nil, err
		}
		if wait != nil {
			return *wait, nil
		}
		if denied {
			return ToolResultEnvelope{OK: false, Error: &ToolError{Code: "permission_denied", Message: "个人数据访问未获授权"}}, nil
		}
	}
	token, _, err := t.grants.IssueRunGrant(call.RunID, userID, []string{t.name}, t.scopes, 90*time.Second, 1)
	if err != nil {
		return nil, err
	}
	defer t.grants.Revoke(token)
	return t.gateway.CallTool(ctx, token, t.name, arguments)
}
