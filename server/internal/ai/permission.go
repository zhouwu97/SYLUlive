package ai

import (
	"context"
	"errors"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type PermissionDecision string

const (
	PermissionDecisionAllow PermissionDecision = "allow"
	PermissionDecisionAsk   PermissionDecision = "ask"
	PermissionDecisionDeny  PermissionDecision = "deny"
)

// permissionDecision 合并长期策略与当前 Run 的一次性授权。
// ask 没有有效的 Run 授权记录时始终返回 Ask，不会降级成允许。
func (mcp *campusMCP) permissionDecision(ctx context.Context, userID uint, scope models.AIUserPermissionScope) (PermissionDecision, error) {
	if userID == 0 || !scope.Valid() {
		return PermissionDecisionDeny, errors.New("invalid_permission_scope")
	}
	if mcp.permissions == nil {
		return PermissionDecisionAllow, nil
	}
	policy, err := mcp.permissions.Policy(ctx, userID, scope)
	if err != nil {
		return PermissionDecisionDeny, err
	}
	switch policy {
	case models.AIUserPermissionAlways:
		return PermissionDecisionAllow, nil
	case models.AIUserPermissionNever:
		return PermissionDecisionDeny, nil
	case models.AIUserPermissionAsk:
		call, ok := currentToolCallContext(ctx)
		if !ok || mcp.db == nil {
			return PermissionDecisionAsk, nil
		}
		now := time.Now()
		if mcp.now != nil {
			now = mcp.now()
		}
		var consent models.AIRunConsent
		err := mcp.db.WithContext(ctx).Where(
			"run_id = ? AND user_id = ? AND scope = ? AND expires_at > ?",
			call.RunID, userID, scope, now,
		).First(&consent).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return PermissionDecisionAsk, nil
		}
		if err != nil {
			return PermissionDecisionDeny, err
		}
		if consent.Granted {
			return PermissionDecisionAllow, nil
		}
		return PermissionDecisionDeny, nil
	default:
		return PermissionDecisionDeny, nil
	}
}

// requirePermission 在 ask 时构造可持久化的等待结果；调用方必须在读取数据前执行。
func (mcp *campusMCP) requirePermission(ctx context.Context, userID uint, scope models.AIUserPermissionScope, reason string) (*ToolWait, bool, error) {
	decision, err := mcp.permissionDecision(ctx, userID, scope)
	if err != nil {
		return nil, true, err
	}
	switch decision {
	case PermissionDecisionAllow:
		return nil, false, nil
	case PermissionDecisionDeny:
		return nil, true, nil
	case PermissionDecisionAsk:
		if _, ok := currentToolCallContext(ctx); !ok {
			return nil, true, errors.New("missing_tool_call_context")
		}
		return &ToolWait{
			State: models.AIRunStateWaitingUserConsent, EventType: "consent.required", ConsentScope: scope,
			Payload: map[string]interface{}{"scope": scope, "reason": reason},
		}, false, nil
	default:
		return nil, true, errors.New("permission_denied")
	}
}
