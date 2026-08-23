package ai

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// AgentPlanner 是唯一允许模型/规划框架参与的边界。
// Planner 不持有用户身份、Grant、数据库连接或副作用客户端。
type AgentPlanner interface {
	Next(context.Context, AgentRunState, []AgentCapability) (AgentDecision, error)
}

// AgentCapabilityExecutor 负责把已通过 Control Plane 校验的语义能力映射到本地工具或 MCP。
// 实现必须自行从受控 Context 解析当前 Run 的用户身份。
type AgentCapabilityExecutor interface {
	Execute(context.Context, string, AgentToolCall) (ToolResultEnvelope, error)
}

type AgentOrchestratorConfig struct {
	Clock         func() time.Time
	Activity      func(context.Context, AgentActivityEvent)
	MaxCandidates int
}

type AgentRunInput struct {
	RunID       string
	Message     string
	PageContext *AgentContextEnvelope
	Goal        *GoalSpec
}

type AgentRunResult struct {
	State       AgentRunState
	Decision    AgentDecision
	Activities  []AgentActivityEvent
	ToolResults []ToolResultEnvelope
}

type AgentOrchestrator struct {
	capabilities []AgentCapability
	planner      AgentPlanner
	executor     AgentCapabilityExecutor
	config       AgentOrchestratorConfig
}

func NewAgentOrchestrator(capabilities []AgentCapability, planner AgentPlanner, executor AgentCapabilityExecutor, config AgentOrchestratorConfig) (*AgentOrchestrator, error) {
	if planner == nil || executor == nil {
		return nil, errors.New("agent_orchestrator_dependencies_required")
	}
	if config.Clock == nil {
		config.Clock = time.Now
	}
	if config.MaxCandidates <= 0 || config.MaxCandidates > 32 {
		config.MaxCandidates = 12
	}
	copyCapabilities := append([]AgentCapability(nil), capabilities...)
	return &AgentOrchestrator{capabilities: copyCapabilities, planner: planner, executor: executor, config: config}, nil
}

func (o *AgentOrchestrator) Run(ctx context.Context, input AgentRunInput) (AgentRunResult, error) {
	if o == nil || o.planner == nil || o.executor == nil {
		return AgentRunResult{}, errors.New("agent_orchestrator_unavailable")
	}
	if strings.TrimSpace(input.RunID) == "" || strings.TrimSpace(input.Message) == "" {
		return AgentRunResult{}, errors.New("agent_run_input_invalid")
	}
	goal := ParseGoalSpec(input.Message, input.PageContext)
	if input.Goal != nil {
		goal = *input.Goal
	}
	state := AgentRunState{RunID: input.RunID, Goal: goal, Budget: BudgetForGoal(goal), ConstraintVersion: 1, PlanVersion: 1}
	tracker := NewBudgetTracker(state.Budget)
	activities := make([]AgentActivityEvent, 0, 16)
	results := make([]ToolResultEnvelope, 0, 8)
	emit := func(event AgentActivityEvent) {
		if event.CreatedAt.IsZero() {
			event.CreatedAt = o.config.Clock()
		}
		activities = append(activities, event)
		if o.config.Activity != nil {
			o.config.Activity(ctx, event)
		}
	}
	emit(AgentActivityEvent{Type: "goal.updated", ActivityCode: "goal_initialized", Text: "已理解当前目标"})

	deadline := state.Budget.MaxDuration
	if deadline > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, deadline)
		defer cancel()
	}
	for {
		if err := ctx.Err(); err != nil {
			return AgentRunResult{State: state, Activities: activities, ToolResults: results}, err
		}
		if err := tracker.BeginPlanningRound(); err != nil {
			return AgentRunResult{State: state, Activities: activities, ToolResults: results}, err
		}
		planningQuery := agentPlanningQuery(state.Goal)
		candidates := RetrieveCapabilities(planningQuery, o.capabilities, nil, o.config.MaxCandidates)
		candidates = filterUnavailableCapabilities(candidates, state.UnavailableCapabilities)
		allowed := make(map[string]AgentCapability, len(candidates))
		for _, candidate := range candidates {
			if candidate.Available {
				allowed[candidate.ID] = candidate
			}
		}
		decision, err := o.planner.Next(ctx, state, candidates)
		if err != nil {
			return AgentRunResult{State: state, Activities: activities, ToolResults: results}, err
		}
		if err := ValidateAgentDecision(decision, allowed); err != nil {
			return AgentRunResult{State: state, Decision: decision, Activities: activities, ToolResults: results}, err
		}
		if decision.GoalUpdate != nil {
			if err := applyAgentGoalUpdate(&state, *decision.GoalUpdate); err != nil {
				return AgentRunResult{State: state, Decision: decision, Activities: activities, ToolResults: results}, err
			}
			emit(AgentActivityEvent{Type: "goal.updated", ActivityCode: "goal_reconciled", Text: "已保留原目标并更新派生计划"})
		}
		switch decision.Type {
		case DecisionToolCall:
			call := *decision.ToolCall
			capability := allowed[call.Capability]
			if err := tracker.Admit(call.Capability, call.Arguments, false); err != nil {
				return AgentRunResult{State: state, Decision: decision, Activities: activities, ToolResults: results}, err
			}
			if capability.SideEffect == SideEffectExternal {
				if err := tracker.AdmitExternalCall(); err != nil {
					return AgentRunResult{State: state, Decision: decision, Activities: activities, ToolResults: results}, err
				}
			}
			emit(AgentActivityEvent{Type: "tool.started", ActivityCode: "capability_execution", ToolName: call.Capability, Text: capability.Description})
			result, executeErr := o.executor.Execute(ctx, state.RunID, call)
			if executeErr != nil {
				if isCapabilityUnavailableError(executeErr) {
					state.UnavailableCapabilities = appendUniqueAgentStrings(state.UnavailableCapabilities, call.Capability)
				}
				state.Failures = append(state.Failures, ToolError{Code: "tool_execution_failed", Message: executeErr.Error(), Retryable: true})
				result = ToolResultEnvelope{OK: false, Error: &ToolError{Code: "tool_execution_failed", Message: executeErr.Error(), Retryable: true}}
				results = append(results, result)
				state.Observations = append(state.Observations, AgentObservation{Capability: call.Capability, Result: result, CreatedAt: o.config.Clock()})
				emit(AgentActivityEvent{Type: "tool.completed", ActivityCode: "failed", ToolName: call.Capability, Text: "能力执行失败，正在重新规划"})
				state.PlanVersion++
				emit(AgentActivityEvent{Type: "plan.revised", ActivityCode: "replan_after_failure", ToolName: call.Capability, Text: "已根据失败结果重新规划"})
				continue
			}
			results = append(results, result)
			state.Observations = append(state.Observations, AgentObservation{Capability: call.Capability, Result: result, CreatedAt: o.config.Clock()})
			state.CompletedSteps = append(state.CompletedSteps, call.Capability)
			state.KnownFacts = append(state.KnownFacts, observedFact(call.Capability, result))
			if !result.OK && result.Error != nil {
				state.Failures = append(state.Failures, *result.Error)
			}
			if err := tracker.ObserveResult(result); err != nil {
				return AgentRunResult{State: state, Decision: decision, Activities: activities, ToolResults: results}, err
			}
			emit(AgentActivityEvent{Type: "tool.completed", ActivityCode: resultActivityCode(result), ToolName: call.Capability, Text: "已获得能力结果"})
			state.PlanVersion++
			emit(AgentActivityEvent{Type: "plan.revised", ActivityCode: "replan_after_observation", ToolName: call.Capability, Text: "已根据新事实重新规划"})
		case DecisionProposeAction:
			proposal := *decision.ActionDraft
			if proposal.IdempotencyKey == "" {
				proposal.IdempotencyKey = actionIdempotencyKey(state.RunID, proposal)
			}
			state.PendingActions = append(state.PendingActions, proposal)
			emit(AgentActivityEvent{Type: "approval.required", ActivityCode: "action_confirmation", Text: proposal.Preview})
			return AgentRunResult{State: state, Decision: decision, Activities: activities, ToolResults: results}, nil
		case DecisionRequestUser, DecisionRespond:
			return AgentRunResult{State: state, Decision: decision, Activities: activities, ToolResults: results}, nil
		}
	}
}

func filterUnavailableCapabilities(candidates []AgentCapability, unavailable []string) []AgentCapability {
	if len(unavailable) == 0 {
		return candidates
	}
	blocked := make(map[string]struct{}, len(unavailable))
	for _, value := range unavailable {
		blocked[strings.TrimSpace(value)] = struct{}{}
	}
	result := make([]AgentCapability, 0, len(candidates))
	for _, candidate := range candidates {
		if _, found := blocked[candidate.ID]; !found {
			result = append(result, candidate)
		}
	}
	return result
}

func isCapabilityUnavailableError(err error) bool {
	if err == nil {
		return false
	}
	value := strings.ToLower(err.Error())
	return strings.Contains(value, "mcp_v5_connect") || strings.Contains(value, "mcp_v5_call") ||
		strings.Contains(value, "mcp_unavailable") || strings.Contains(value, "timeout")
}

func resultActivityCode(result ToolResultEnvelope) string {
	if result.OK {
		return "success"
	}
	if result.Error != nil && result.Error.Retryable {
		return "retryable_failure"
	}
	return "failure"
}

func agentPlanningQuery(goal GoalSpec) string {
	parts := []string{goal.Objective}
	for _, constraint := range append(append([]GoalConstraint{}, goal.HardConstraints...), goal.SoftConstraints...) {
		parts = append(parts, constraint.Text)
	}
	parts = append(parts, goal.DerivedSubgoals...)
	return strings.TrimSpace(strings.Join(parts, " "))
}

func observedFact(capability string, result ToolResultEnvelope) string {
	status := "failed"
	if result.OK {
		status = "ok"
	}
	return capability + ":" + status
}

func applyAgentGoalUpdate(state *AgentRunState, update GoalSpec) error {
	if state == nil {
		return errors.New("agent_state_required")
	}
	if strings.TrimSpace(update.Objective) != "" && strings.TrimSpace(update.Objective) != strings.TrimSpace(state.Goal.Objective) {
		return errors.New("agent_goal_objective_immutable")
	}
	state.Goal.RequiresPersonalContext = state.Goal.RequiresPersonalContext || update.RequiresPersonalContext
	state.Goal.Unknowns = appendUniqueAgentStrings(state.Goal.Unknowns, update.Unknowns...)
	state.Goal.DerivedSubgoals = appendUniqueAgentStrings(nil, update.DerivedSubgoals...)
	for _, constraint := range append(append([]GoalConstraint{}, update.HardConstraints...), update.SoftConstraints...) {
		if strings.TrimSpace(constraint.Text) == "" {
			continue
		}
		if constraint.Hard {
			state.Goal.HardConstraints = appendUniqueConstraints(state.Goal.HardConstraints, constraint)
		} else {
			state.Goal.SoftConstraints = appendUniqueConstraints(state.Goal.SoftConstraints, constraint)
		}
	}
	state.Budget = BudgetForGoal(state.Goal)
	return nil
}

func appendUniqueAgentStrings(values []string, additions ...string) []string {
	seen := make(map[string]struct{}, len(values)+len(additions))
	result := make([]string, 0, len(values)+len(additions))
	for _, value := range append(values, additions...) {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func appendUniqueConstraints(values []GoalConstraint, additions ...GoalConstraint) []GoalConstraint {
	result := append([]GoalConstraint(nil), values...)
	for _, addition := range additions {
		duplicate := false
		for _, existing := range result {
			if existing.Text == addition.Text && existing.Hard == addition.Hard {
				duplicate = true
				break
			}
		}
		if !duplicate {
			result = append(result, addition)
		}
	}
	return result
}

func actionIdempotencyKey(runID string, proposal AgentActionProposal) string {
	payload, _ := json.Marshal(struct {
		RunID  string          `json:"run_id"`
		Action string          `json:"action"`
		Args   json.RawMessage `json:"arguments"`
	}{runID, proposal.Action, proposal.Arguments})
	return fmt.Sprintf("agent-%x", sha256Bytes(payload)[:24])
}

func sha256Bytes(value []byte) []byte {
	// 通过标准库哈希保持 key 稳定，避免把完整参数写入 idempotency key。
	hash := sha256.Sum256(value)
	return hash[:]
}

// UpdateConstraints 供用户在 Run 进行期间追加约束。
// 旧的待确认动作会被清空，调用方必须重新 validate 后才能再次提出 Action Proposal。
func (o *AgentOrchestrator) UpdateConstraints(state *AgentRunState, constraints []GoalConstraint) error {
	if state == nil {
		return errors.New("agent_state_required")
	}
	changed := false
	for _, constraint := range constraints {
		if strings.TrimSpace(constraint.Text) == "" {
			continue
		}
		if constraint.Hard {
			updated := appendUniqueConstraints(state.Goal.HardConstraints, constraint)
			changed = changed || len(updated) != len(state.Goal.HardConstraints)
			state.Goal.HardConstraints = updated
		} else {
			updated := appendUniqueConstraints(state.Goal.SoftConstraints, constraint)
			changed = changed || len(updated) != len(state.Goal.SoftConstraints)
			state.Goal.SoftConstraints = updated
		}
	}
	if !changed {
		return nil
	}
	state.ConstraintVersion++
	state.PlanVersion++
	state.PendingActions = nil
	state.Budget = BudgetForGoal(state.Goal)
	return nil
}
