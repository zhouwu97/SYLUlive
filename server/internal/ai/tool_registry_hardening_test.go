package ai

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"shenliyuan/internal/models"
)

type delayedPureReadTool struct {
	started chan struct{}
	release chan struct{}
}

func (tool *delayedPureReadTool) Name() string    { return "competition.delayed" }
func (tool *delayedPureReadTool) Version() string { return "test" }
func (tool *delayedPureReadTool) Definition() ToolDefinition {
	return ToolDefinition{Name: "competition.delayed", Description: "测试延迟结果", Parameters: map[string]interface{}{"type": "object"}}
}
func (tool *delayedPureReadTool) Execute(ctx context.Context, _ uint, _ json.RawMessage) (interface{}, error) {
	close(tool.started)
	select {
	case <-tool.release:
		return map[string]interface{}{"status": "ok", "data": map[string]interface{}{"deadline": "2026-09-01"}}, nil
	case <-ctx.Done():
		// 模拟不尊重取消信号的远端工具；结果必须仍由版本栅栏丢弃。
		<-tool.release
		return map[string]interface{}{"status": "late", "data": map[string]interface{}{"deadline": "2026-09-01"}}, nil
	}
}

func TestToolRegistryDiscardsLateResultAfterConstraintVersionChanges(t *testing.T) {
	db := newRuntimeTestDB(t)
	run := models.AIRun{
		ID: "run-stale-fence", UserID: 7, ConversationID: "conversation-stale-fence", ClientRequestID: "request-stale-fence",
		State: models.AIRunStatePlanning, Provider: "test", Model: "test", MessageHash: "hash", MessageLength: 2,
		ExpiresAt: time.Now().Add(time.Minute), PlanningRound: 1, ConstraintVersion: 1, PlanVersion: 1,
	}
	require.NoError(t, db.Create(&run).Error)
	delayed := &delayedPureReadTool{started: make(chan struct{}), release: make(chan struct{})}
	registry, err := NewToolRegistry(db, delayed)
	require.NoError(t, err)
	ctx := withAgentPlanContext(context.Background(), AgentTraceFields{RunID: run.ID, PlanningRound: 1, ConstraintVersion: 1, PlanVersion: 1})
	resultCh := make(chan error, 1)
	go func() {
		_, _, executeErr := registry.Execute(ctx, "late-call", run.ID, run.UserID, "competition.delayed", json.RawMessage(`{}`))
		resultCh <- executeErr
	}()
	<-delayed.started
	require.NoError(t, db.Model(&models.AIRun{}).Where("id = ?", run.ID).Updates(map[string]interface{}{
		"planning_round": 2, "constraint_version": 2, "plan_version": 2,
	}).Error)
	close(delayed.release)
	require.ErrorIs(t, <-resultCh, ErrStaleToolResult)
	var call models.AIToolCall
	require.NoError(t, db.First(&call, "call_id = ?", "late-call").Error)
	require.Equal(t, "discarded", call.Status)
	require.Nil(t, call.ResultJSON)
}
