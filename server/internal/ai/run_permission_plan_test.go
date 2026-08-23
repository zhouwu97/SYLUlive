package ai

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestPermissionDecisionReusesOneGrantedRunPlan(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:run-permission-plan?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.AIRunConsent{}))
	call := toolCallContext{RunID: "run-plan", CallID: "call-plan", UserID: 7, ToolName: "hy3_decision.analyze_academic"}
	ctx := context.WithValue(context.Background(), toolCallContextKey{}, call)
	mcp := &campusMCP{db: db, permissions: fixedRunPlanPermissionReader{policy: models.AIUserPermissionAsk}}
	require.NoError(t, db.Create(&models.AIRunConsent{
		RunID: call.RunID, UserID: 7, Scope: models.AIUserPermissionPersonalDataAccess,
		Granted: true, ExpiresAt: time.Now().Add(time.Hour),
	}).Error)
	decision, err := mcp.permissionDecision(ctx, 7, models.AIUserPermissionRemoteEduRefresh)
	require.NoError(t, err)
	require.Equal(t, PermissionDecisionAllow, decision)
}

type fixedRunPlanPermissionReader struct{ policy models.AIUserPermissionPolicy }

func (reader fixedRunPlanPermissionReader) Policy(context.Context, uint, models.AIUserPermissionScope) (models.AIUserPermissionPolicy, error) {
	return reader.policy, nil
}
