package ai

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"shenliyuan/internal/models"
)

func TestPermissionDecisionFailsClosedWithoutPermissionReader(t *testing.T) {
	mcp := &campusMCP{now: time.Now}

	decision, err := mcp.permissionDecision(
		context.Background(), 7, models.AIUserPermissionPersonalDataAccess,
	)

	// 漏传权限读取器是装配错误，不能静默变成允许。
	require.ErrorIs(t, err, ErrPermissionServiceUnavailable)
	require.Equal(t, PermissionDecisionDeny, decision)
}

func TestRequirePermissionSurfacesMissingPermissionServiceAsError(t *testing.T) {
	mcp := &campusMCP{now: time.Now}

	wait, blocked, err := mcp.requirePermission(
		context.Background(), 7, models.AIUserPermissionPersonalDataAccess, "读取成绩",
	)

	require.ErrorIs(t, err, ErrPermissionServiceUnavailable)
	require.True(t, blocked)
	require.Nil(t, wait)
}

func TestAllowAllPermissionReaderOnlyForExplicitTestWiring(t *testing.T) {
	mcp := &campusMCP{now: time.Now, permissions: AllowAllPermissionReader{}}

	decision, err := mcp.permissionDecision(
		context.Background(), 7, models.AIUserPermissionPersonalDataAccess,
	)

	require.NoError(t, err)
	require.Equal(t, PermissionDecisionAllow, decision)
}
