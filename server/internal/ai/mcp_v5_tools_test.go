package ai

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"shenliyuan/internal/models"
)

func TestMCPV5PersonalToolFailsClosedWithoutPermissionService(t *testing.T) {
	tool := &mcpV5Tool{
		grants: NewScopedGrantManager(time.Now), name: "academic.summary", scopes: []string{"academic:summary"}, now: time.Now,
	}
	ctx := withToolCallContext(context.Background(), "run-v5", "call-v5", 7, tool.name)

	_, err := tool.Execute(ctx, 7, json.RawMessage(`{}`))

	require.ErrorIs(t, err, ErrPermissionServiceUnavailable)
}

func TestMCPV5PersonalToolWaitsForRunConsentBeforeIssuingGrant(t *testing.T) {
	db := newRuntimeTestDB(t)
	tool := &mcpV5Tool{
		grants: NewScopedGrantManager(time.Now), name: "schedule.free_windows", scopes: []string{"schedule:read"},
		permissions: fixedPersonalDataPermissionReader{models.AIUserPermissionPersonalDataAccess: models.AIUserPermissionAsk},
		db:          db, now: time.Now,
	}
	ctx := withToolCallContext(context.Background(), "run-v5-consent", "call-v5-consent", 7, tool.name)

	value, err := tool.Execute(ctx, 7, json.RawMessage(`{"from":"2026-08-23T00:00:00Z","to":"2026-08-24T00:00:00Z"}`))

	require.NoError(t, err)
	wait, ok := value.(ToolWait)
	require.True(t, ok)
	require.Equal(t, models.AIRunStateWaitingUserConsent, wait.State)
	require.Equal(t, models.AIUserPermissionPersonalDataAccess, wait.ConsentScope)
}

func TestMCPV5PersonalToolReturnsDeniedEnvelope(t *testing.T) {
	tool := &mcpV5Tool{
		grants: NewScopedGrantManager(time.Now), name: "academic.summary", scopes: []string{"academic:summary"}, now: time.Now,
		permissions: fixedPersonalDataPermissionReader{models.AIUserPermissionPersonalDataAccess: models.AIUserPermissionNever},
	}
	ctx := withToolCallContext(context.Background(), "run-v5-deny", "call-v5-deny", 7, tool.name)

	value, err := tool.Execute(ctx, 7, json.RawMessage(`{}`))

	require.NoError(t, err)
	envelope, ok := value.(ToolResultEnvelope)
	require.True(t, ok)
	require.False(t, envelope.OK)
	require.Equal(t, "permission_denied", envelope.Error.Code)
}
