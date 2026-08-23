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

// ErrPermissionServiceUnavailable 表示权限读取器缺失，属于装配错误而不是用户拒绝。
var ErrPermissionServiceUnavailable = errors.New("permission_service_unavailable")

// AllowAllPermissionReader 只供测试显式放行使用。
// 生产装配必须注入真实权限服务；不能再依赖 nil 隐式放行。
type AllowAllPermissionReader struct{}

func (AllowAllPermissionReader) Policy(context.Context, uint, models.AIUserPermissionScope) (models.AIUserPermissionPolicy, error) {
	return models.AIUserPermissionAlways, nil
}

// permissionDecision 合并长期策略与当前 Run 的一次性授权。
// ask 没有有效的 Run 授权记录时始终返回 Ask，不会降级成允许。
func (mcp *campusMCP) permissionDecision(ctx context.Context, userID uint, scope models.AIUserPermissionScope) (PermissionDecision, error) {
	if userID == 0 || !scope.Valid() {
		return PermissionDecisionDeny, errors.New("invalid_permission_scope")
	}
	if mcp.permissions == nil {
		// fail-closed：漏传权限读取器时必须拒绝并报错。
		// 从前这里返回 Allow，只要新增一个测试入口、CLI 或后台任务忘记注入，
		// 成绩、课表和二课访问就会静默变成允许。
		return PermissionDecisionDeny, ErrPermissionServiceUnavailable
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
			// 一个 Run 的个人数据计划只展示一次普通用户确认。当前
			// scope 未单独记录时，已批准的同一 Run 计划覆盖其它只读/刷新 scope。
			// 写操作不经过校园个人数据权限链路，仍保持独立确认。
			var planConsent models.AIRunConsent
			planErr := mcp.db.WithContext(ctx).Where(
				"run_id = ? AND user_id = ? AND granted = ? AND expires_at > ?",
				call.RunID, userID, true, now,
			).First(&planConsent).Error
			if planErr == nil && isRunPermissionPlanScope(scope) {
				return PermissionDecisionAllow, nil
			}
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

func isRunPermissionPlanScope(scope models.AIUserPermissionScope) bool {
	switch scope {
	case models.AIUserPermissionPersonalDataAccess,
		models.AIUserPermissionDeviceCacheAccess,
		models.AIUserPermissionRemoteEduRefresh,
		models.AIUserPermissionErkeSnapshotUpload,
		models.AIUserPermissionAcademicCloudStorage,
		models.AIUserPermissionExternalModelAnalysis:
		return true
	default:
		return false
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
