package ai

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"gorm.io/datatypes"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// loadRuntimeAgentState 从 Run 快照恢复控制面状态。快照损坏时拒绝恢复，
// 不能退回到“重新理解用户目标”的隐式路径。
func (r *Runtime) loadRuntimeAgentState(ctx context.Context, run *models.AIRun, message string) (AgentRunState, error) {
	if run == nil || strings.TrimSpace(run.ID) == "" {
		return AgentRunState{}, errors.New("agent_state_run_required")
	}
	var state AgentRunState
	if len(run.AgentStateJSON) > 0 && string(run.AgentStateJSON) != "{}" {
		if !json.Valid(run.AgentStateJSON) || json.Unmarshal(run.AgentStateJSON, &state) != nil {
			return AgentRunState{}, errors.New("agent_state_corrupt")
		}
		if state.RunID != "" && state.RunID != run.ID {
			return AgentRunState{}, errors.New("agent_state_run_mismatch")
		}
		state.RunID = run.ID
		if r.config.FeatureFlagsConfigured && state.FeatureFlags == (FeatureFlagSnapshot{}) {
			state.FeatureFlags = r.config.FeatureFlags.Snapshot(FeatureFlagInput{
				UserID: run.UserID, RunID: run.ID, Mode: state.ExecutionMode,
			})
		}
		if r.config.FeatureFlagsConfigured && !state.FeatureFlags.DeepModeEnabled && state.ExecutionMode == ExecutionDeep {
			state.ExecutionMode = ExecutionNormal
			state.ExecutionProfile = DefaultExecutionProfile(ExecutionNormal)
			state.Budget = BudgetForExecutionProfile(state.ExecutionProfile)
		}
		if state.ExecutionMode == "" || state.ExecutionProfile.MaxToolCalls <= 0 {
			refreshExecutionProfile(&state)
		} else if state.Budget.MaxToolCalls <= 0 {
			state.Budget = BudgetForExecutionProfile(state.ExecutionProfile)
		}
		state.Budget.MaxDuration = time.Duration(state.Budget.MaxDurationMs) * time.Millisecond
		if state.ConstraintVersion <= 0 {
			state.ConstraintVersion = maxInt(run.ConstraintVersion, 1)
		}
		if state.PlanVersion <= 0 {
			state.PlanVersion = maxInt(run.PlanVersion, 1)
		}
		return state, nil
	}
	if strings.TrimSpace(message) == "" {
		return AgentRunState{}, errors.New("agent_state_missing")
	}
	goal := ParseGoalSpec(message, decodeAgentContextPointer(run.AgentContext))
	profile := ExecutionProfileForGoal(goal)
	state = AgentRunState{
		RunID: run.ID, Goal: goal, ExecutionMode: profile.Mode, ExecutionProfile: profile,
		FeatureFlags:      r.config.FeatureFlags.Snapshot(FeatureFlagInput{UserID: run.UserID, RunID: run.ID, Mode: profile.Mode}),
		Budget:            BudgetForExecutionProfile(profile),
		ConstraintVersion: maxInt(run.ConstraintVersion, 1), PlanVersion: maxInt(run.PlanVersion, 1),
		PlanningRounds: run.PlanningRound,
	}
	if r.config.FeatureFlagsConfigured && !state.FeatureFlags.DeepModeEnabled && state.ExecutionMode == ExecutionDeep {
		state.ExecutionMode = ExecutionNormal
		state.ExecutionProfile = DefaultExecutionProfile(ExecutionNormal)
		state.Budget = BudgetForExecutionProfile(state.ExecutionProfile)
	}
	return state, nil
}

func decodeAgentContextPointer(raw []byte) *AgentContextEnvelope {
	envelope, ok := decodeAgentContext(raw)
	if !ok {
		return nil
	}
	return &envelope
}

// persistRuntimeAgentState 使用单次更新保存控制面状态，字段只包含可审计的
// 目标摘要、预算计数、观察摘要和版本号，不把原始工具数据写进 Run。
func (r *Runtime) persistRuntimeAgentState(ctx context.Context, run *models.AIRun, state AgentRunState) error {
	if r == nil || r.db == nil || run == nil || state.RunID != run.ID {
		return errors.New("agent_state_persist_invalid")
	}
	state.Budget.MaxDuration = 0
	payload, err := json.Marshal(state)
	if err != nil || len(payload) > 256<<10 {
		return errors.New("agent_state_encode_failed")
	}
	result := r.db.WithContext(ctx).Model(&models.AIRun{}).
		Where("id = ? AND state_version = ? AND constraint_version = ?", run.ID, run.StateVersion, run.ConstraintVersion).
		Updates(map[string]interface{}{
			"agent_state_json": datatypes.JSON(payload), "planning_round": state.PlanningRounds,
			"constraint_version": state.ConstraintVersion, "plan_version": state.PlanVersion,
			"state_version": gorm.Expr("state_version + 1"),
			"updated_at":    time.Now(),
		})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected != 1 {
		return errors.New("agent_state_version_conflict")
	}
	run.AgentStateJSON = datatypes.JSON(payload)
	run.PlanningRound = state.PlanningRounds
	run.ConstraintVersion = state.ConstraintVersion
	run.PlanVersion = state.PlanVersion
	run.StateVersion++
	return nil
}

func maxInt(left, right int) int {
	if left > right {
		return left
	}
	return right
}

// beginRuntimePlanningRound 建立工具调用的规划轮次。每个工具调用都必须
// 带着这一轮和 ConstraintVersion，旧轮结果即使晚到也不能进入模型消息。
func (r *Runtime) beginRuntimePlanningRound(ctx context.Context, run *models.AIRun, state *AgentRunState) error {
	if run == nil || state == nil {
		return errors.New("agent_state_required")
	}
	state.PlanningRounds++
	run.PlanningRound = state.PlanningRounds
	if state.ConstraintVersion <= 0 {
		state.ConstraintVersion = maxInt(run.ConstraintVersion, 1)
	}
	if state.PlanVersion <= 0 {
		state.PlanVersion = maxInt(run.PlanVersion, 1)
	}
	return r.persistRuntimeAgentState(ctx, run, *state)
}

func addRuntimeObservation(state *AgentRunState, capability string, raw json.RawMessage, createdAt time.Time) int {
	if state == nil {
		return 0
	}
	envelope, err := DecodeToolResult(raw)
	if err != nil {
		envelope = ToolResultEnvelope{OK: false, Error: &ToolError{Code: "tool_result_invalid", Retryable: false}}
	}
	state.Observations = append(state.Observations, AgentObservation{Capability: capability, Result: envelope, CreatedAt: createdAt})
	state.ToolCalls++
	if !envelope.OK && envelope.Error != nil {
		state.Failures = append(state.Failures, *envelope.Error)
	}
	if envelope.OK && len(envelope.Data) > 0 && string(envelope.Data) != "null" {
		state.KnownFacts = appendUniqueAgentStrings(state.KnownFacts, observedFact(capability, envelope))
		return 1
	}
	return 0
}

func filterUnavailableToolDefinitions(definitions []ToolDefinition, unavailable map[string]struct{}) []ToolDefinition {
	if len(unavailable) == 0 {
		return definitions
	}
	result := make([]ToolDefinition, 0, len(definitions))
	for _, definition := range definitions {
		if _, blocked := unavailable[definition.Name]; !blocked {
			result = append(result, definition)
		}
	}
	return result
}

func (r *Runtime) agentTracePayload(run *models.AIRun, payload map[string]interface{}, durationMs int64, newFactCount int) map[string]interface{} {
	result := make(map[string]interface{}, len(payload)+9)
	for key, value := range payload {
		result[key] = value
	}
	if run != nil {
		result["run_id"] = run.ID
		result["planning_round"] = run.PlanningRound
		result["constraint_version"] = run.ConstraintVersion
		result["plan_version"] = run.PlanVersion
		var state AgentRunState
		if len(run.AgentStateJSON) > 0 && json.Unmarshal(run.AgentStateJSON, &state) == nil {
			if state.ExecutionMode != "" {
				result["execution_mode"] = state.ExecutionMode
			}
			if state.ExecutionProfile.MaxToolCalls > 0 {
				result["budget"] = state.ExecutionProfile
			}
		}
	}
	if durationMs > 0 {
		result["duration_ms"] = durationMs
	}
	if newFactCount > 0 {
		result["new_fact_count"] = newFactCount
	}
	return result
}
