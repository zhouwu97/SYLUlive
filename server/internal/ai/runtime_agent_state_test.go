package ai

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/datatypes"

	"shenliyuan/internal/models"
)

func TestRuntimeAgentStateSurvivesRecoveryBoundary(t *testing.T) {
	db := newRuntimeTestDB(t)
	runtime := newTestRuntime(t, db, &MockProvider{Response: ChatResponse{Content: "不会执行"}}, fixedRetriever{})
	goal := ParseGoalSpec("推荐适合我的比赛，但不要影响上课", nil)
	state := AgentRunState{
		RunID: "run-recovery-state", Goal: goal, Budget: BudgetForGoal(goal),
		KnownFacts: []string{"competition.search:ok"}, PlanningRounds: 2, ToolCalls: 1,
		ConstraintVersion: 3, PlanVersion: 5,
	}
	raw, err := json.Marshal(state)
	require.NoError(t, err)
	run := models.AIRun{
		ID: state.RunID, UserID: 7, ConversationID: uuid.NewString(), ClientRequestID: uuid.NewString(),
		State: models.AIRunStateWaitingDevice, Provider: "test", Model: "test", MessageHash: "hash", MessageLength: 10,
		AgentStateJSON: datatypes.JSON(raw), PlanningRound: state.PlanningRounds,
		ConstraintVersion: state.ConstraintVersion, PlanVersion: state.PlanVersion,
		ExpiresAt: time.Now().Add(time.Hour),
	}
	require.NoError(t, db.Create(&run).Error)
	require.NoError(t, db.Create(&models.AIRunResumeJob{
		ID: uuid.NewString(), RunID: run.ID, UserID: run.UserID, WaitingState: models.AIRunStateWaitingDevice,
		MessagesJSON:         datatypes.JSON([]byte(`[{"role":"user","content":"继续"}]`)),
		PendingToolCallsJSON: datatypes.JSON([]byte(`[{"call_id":"call-recovery","tool_name":"device.schedule.ensure_fresh_week","resume_key":"job-recovery"}]`)),
		UsageJSON:            datatypes.JSON([]byte(`{}`)), Status: "waiting", ExpiresAt: run.ExpiresAt,
	}).Error)

	recovered, err := runtime.loadRuntimeAgentState(context.Background(), &run, "不会覆盖原目标")
	require.NoError(t, err)
	require.Equal(t, state.Goal.Objective, recovered.Goal.Objective)
	require.Equal(t, 3, recovered.ConstraintVersion)
	require.Equal(t, 5, recovered.PlanVersion)
	require.Equal(t, []string{"competition.search:ok"}, recovered.KnownFacts)
	require.NoError(t, runtime.RecoverAbandonedRuns(context.Background()))
	var persisted models.AIRun
	require.NoError(t, db.First(&persisted, "id = ?", run.ID).Error)
	require.Equal(t, models.AIRunStateWaitingDevice, persisted.State)
	var resume models.AIRunResumeJob
	require.NoError(t, db.First(&resume, "run_id = ?", run.ID).Error)
	require.Equal(t, "waiting", resume.Status)
}

func TestRuntimeAgentStateUsesStateVersionCASAcrossInstances(t *testing.T) {
	db := newRuntimeTestDB(t)
	runtime := newTestRuntime(t, db, &MockProvider{Response: ChatResponse{Content: "不会执行"}}, fixedRetriever{})
	state := AgentRunState{
		RunID: "run-state-cas", Goal: ParseGoalSpec("只读取公开政策", nil), Budget: AgentBudget{MaxToolCalls: 3},
		ConstraintVersion: 1, PlanVersion: 1,
	}
	raw, err := json.Marshal(state)
	require.NoError(t, err)
	run := models.AIRun{
		ID: "run-state-cas", UserID: 7, ConversationID: uuid.NewString(), ClientRequestID: uuid.NewString(),
		State: models.AIRunStatePlanning, Provider: "test", Model: "test", MessageHash: "hash", MessageLength: 2,
		AgentStateJSON: datatypes.JSON(raw), ConstraintVersion: 1, PlanVersion: 1, ExpiresAt: time.Now().Add(time.Hour),
	}
	require.NoError(t, db.Create(&run).Error)

	// A 与 B 模拟分别从两个 Go 实例读到的同一份旧快照；B 不能覆盖 A 的新状态。
	instanceA := run
	instanceB := run
	stateA := state
	stateA.KnownFacts = []string{"instance-a"}
	stateB := state
	stateB.KnownFacts = []string{"instance-b"}
	require.NoError(t, runtime.persistRuntimeAgentState(context.Background(), &instanceA, stateA))
	require.ErrorContains(t, runtime.persistRuntimeAgentState(context.Background(), &instanceB, stateB), "agent_state_version_conflict")

	var persisted models.AIRun
	require.NoError(t, db.First(&persisted, "id = ?", run.ID).Error)
	require.Equal(t, int64(1), persisted.StateVersion)
	var persistedState AgentRunState
	require.NoError(t, json.Unmarshal(persisted.AgentStateJSON, &persistedState))
	require.Equal(t, []string{"instance-a"}, persistedState.KnownFacts)
}

func TestPersistedTraceRedactsSecretsAndRawToolData(t *testing.T) {
	db := newRuntimeTestDB(t)
	runtime := newTestRuntime(t, db, &MockProvider{}, fixedRetriever{})
	run := models.AIRun{
		ID: "run-trace-redaction", UserID: 7, ConversationID: uuid.NewString(), ClientRequestID: uuid.NewString(),
		State: models.AIRunStatePlanning, Provider: "test", Model: "test", MessageHash: "hash", MessageLength: 2,
		ExpiresAt: time.Now().Add(time.Hour), ConstraintVersion: 1, PlanVersion: 1,
	}
	require.NoError(t, db.Create(&run).Error)
	_, err := runtime.appendEvent(context.Background(), run.ID, "tool.completed", map[string]interface{}{
		"call_id": "secret-call", "tool_name": "academic.summary", "success": true,
		"result":        map[string]interface{}{"password": "super-secret", "student_id": "2400000000"},
		"authorization": "Bearer super-secret-token",
	}, true)
	require.NoError(t, err)
	var event models.AIEvent
	require.NoError(t, db.Where("run_id = ? AND type = ?", run.ID, "tool.completed").First(&event).Error)
	payload := string(event.Payload)
	require.NotContains(t, payload, "super-secret")
	require.NotContains(t, payload, "2400000000")
	require.NotContains(t, payload, "authorization")
	require.Contains(t, payload, "[REDACTED]")
}

func TestResumeReadsCommittedToolResultInsteadOfReexecuting(t *testing.T) {
	db := newRuntimeTestDB(t)
	runtime := newTestRuntime(t, db, &MockProvider{}, fixedRetriever{})
	require.NoError(t, db.Create(&models.AIToolCall{
		CallID: "committed-call", RunID: "run-committed-call", UserID: 7,
		ToolName: "competition.delayed", ToolVersion: "test", ArgumentsJSON: datatypes.JSON([]byte(`{}`)),
		ArgumentsHash: "hash", Status: "completed", StateVersion: 2,
		ResultJSON: datatypes.JSON([]byte(`{"status":"ok","data":{"id":"already-committed"}}`)),
		ExpiresAt:  time.Now().Add(time.Hour),
	}).Error)
	result, committed, err := runtime.readCommittedToolResult(context.Background(), "committed-call", "run-committed-call", 7, "competition.delayed")
	require.NoError(t, err)
	require.True(t, committed)
	require.JSONEq(t, `{"status":"ok","data":{"id":"already-committed"}}`, string(result))
}
