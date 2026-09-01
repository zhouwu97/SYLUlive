package ai

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestParseGoalSpecExtractsConstraintsWithoutChoosingWorkflow(t *testing.T) {
	goal := ParseGoalSpec("帮我找几个适合我的比赛，这学期别太忙，最好不要影响上课", nil)
	require.Equal(t, "recommend", goal.ActionIntent)
	require.True(t, goal.RequiresPersonalContext)
	require.Len(t, goal.HardConstraints, 1)
	require.Len(t, goal.SoftConstraints, 1)
	// 初始目标不是固定的工具计划。
	require.Empty(t, goal.Unknowns)
}

func TestParseGoalSpecImplicitScheduleQueryUsesPersonalBudget(t *testing.T) {
	goal := ParseGoalSpec("这周哪几天下午比较空？", nil)
	require.True(t, goal.RequiresPersonalContext)

	profile := ExecutionProfileForGoal(goal)
	require.Equal(t, ExecutionNormal, profile.Mode)
	require.Equal(t, 2, profile.MaxSameToolCalls)
}

func TestAgentTraceMetricsProducesTrendFields(t *testing.T) {
	var first AgentTraceMetrics
	first.Observe("tool.requested", []byte(`{}`))
	first.Observe("tool.completed", []byte(`{"duration_ms":100}`))
	first.Observe("plan.revised", []byte(`{}`))
	first.Observe("run.completed", []byte(`{}`))
	var second AgentTraceMetrics
	second.Observe("tool.requested", []byte(`{}`))
	second.Observe("tool.requested", []byte(`{}`))
	second.Observe("tool.completed", []byte(`{"duration_ms":300,"capability_status":"unavailable"}`))
	second.Observe("tool.discarded", []byte(`{}`))
	second.Observe("run.failed", []byte(`{}`))

	trend := BuildAgentEvalTrend([]AgentTraceMetrics{first, second})
	require.Equal(t, 2, trend.RunCount)
	require.Equal(t, 0.5, trend.SuccessRate)
	require.Equal(t, 1.5, trend.AverageToolCalls)
	require.Equal(t, 2, trend.P95ToolCalls)
	require.Equal(t, 0.5, trend.ReplanRate)
	require.Equal(t, 1, trend.DiscardedLateResults)
	require.Equal(t, 1, trend.DegradedRuns)
	require.Equal(t, 200.0, trend.AverageRunLatencyMs)
}

func TestContextBrokerNeverReturnsIdentityLayer(t *testing.T) {
	broker := NewContextBroker()
	require.NoError(t, broker.Register(ContextIdentity, func(context.Context, ContextRequest) ([]ContextValue, error) {
		return []ContextValue{{Layer: ContextIdentity, Key: "user_id", Value: json.RawMessage(`123`)}}, nil
	}))
	require.NoError(t, broker.Register(ContextLive, func(context.Context, ContextRequest) ([]ContextValue, error) {
		return []ContextValue{{Layer: ContextLive, Key: "schedule", Value: json.RawMessage(`{"events":[]`)}}, nil
	}))
	values, err := broker.Resolve(context.Background(), ContextRequest{Layers: []ContextLayer{ContextIdentity, ContextLive}})
	require.NoError(t, err)
	require.Len(t, values, 1)
	require.Equal(t, ContextLive, values[0].Layer)
}

func TestToolResultEnvelopeWrapsLegacyAndPreservesFailure(t *testing.T) {
	legacy, err := DecodeToolResult(json.RawMessage(`{"value":1}`))
	require.NoError(t, err)
	require.True(t, legacy.OK)
	require.Equal(t, FreshnessLive, legacy.Freshness)

	failure, err := DecodeToolResult(json.RawMessage(`{"ok":false,"error":{"code":"DATA_STALE","retryable":true}}`))
	require.NoError(t, err)
	require.False(t, failure.OK)
	require.Equal(t, "DATA_STALE", failure.Error.Code)
}

func TestBudgetTrackerRejectsDuplicateUnlessRetryable(t *testing.T) {
	tracker := NewBudgetTracker(AgentBudget{Class: BudgetNormal, MaxToolCalls: 2})
	args := json.RawMessage(`{"date":"2026-08-23"}`)
	require.NoError(t, tracker.Admit("calendar.get_day", args, false))
	require.EqualError(t, tracker.Admit("calendar.get_day", args, false), "agent_duplicate_tool_call")
	require.NoError(t, tracker.Admit("calendar.get_day", args, true))
	require.Error(t, tracker.Admit("calendar.get_day", args, true))
}

func TestBudgetTrackerStopsSameToolPlanningAndInformationStall(t *testing.T) {
	tracker := NewBudgetTracker(AgentBudget{
		MaxToolCalls: 5, MaxSameToolCalls: 2, MaxPlanningRounds: 2,
		MaxExternalCalls: 1, MaxConsecutiveNoGain: 2,
	})
	args := json.RawMessage(`{"query":"算法"}`)
	require.NoError(t, tracker.BeginPlanningRound())
	require.NoError(t, tracker.Admit("competition.search", args, true))
	require.NoError(t, tracker.Admit("competition.search", json.RawMessage(`{"query":"机器学习"}`), true))
	require.EqualError(t, tracker.Admit("competition.search", json.RawMessage(`{"query":"嵌入式"}`), true), "agent_same_tool_budget_exhausted")
	require.NoError(t, tracker.AdmitExternalCall())
	require.EqualError(t, tracker.AdmitExternalCall(), "agent_external_budget_exhausted")

	result := ToolResultEnvelope{OK: true, Data: json.RawMessage(`{"items":[]}`)}
	require.NoError(t, tracker.ObserveResult(result))
	require.NoError(t, tracker.ObserveResult(result))
	require.EqualError(t, tracker.ObserveResult(result), "agent_information_stalled")
	require.NoError(t, tracker.BeginPlanningRound())
	require.EqualError(t, tracker.BeginPlanningRound(), "agent_planning_budget_exhausted")
}

func TestValidateAgentDecisionRejectsIdentityArgumentsAndUnconfirmedAction(t *testing.T) {
	allowed := map[string]AgentCapability{"academic.summary": {ID: "academic.summary", Available: true}}
	require.Error(t, ValidateAgentDecision(AgentDecision{Type: DecisionToolCall, ToolCall: &AgentToolCall{Capability: "academic.summary", Arguments: json.RawMessage(`{"user_id":7}`)}}, allowed))
	require.Error(t, ValidateAgentDecision(AgentDecision{Type: DecisionProposeAction, ActionDraft: &AgentActionProposal{Action: "calendar.create"}}, allowed))
}

type scriptedAgentPlanner struct{ calls int }

func (p *scriptedAgentPlanner) Next(_ context.Context, _ AgentRunState, _ []AgentCapability) (AgentDecision, error) {
	p.calls++
	if p.calls == 1 {
		return AgentDecision{Type: DecisionToolCall, ToolCall: &AgentToolCall{ID: "call-1", Capability: "competition.search", Arguments: json.RawMessage(`{"query":"算法"}`)}}, nil
	}
	return AgentDecision{Type: DecisionProposeAction, ActionDraft: &AgentActionProposal{Action: "calendar.create", Preview: "添加训练计划", Arguments: json.RawMessage(`{"blocks":[]}`), RequiresConfirmation: true}}, nil
}

type scriptedAgentExecutor struct{}

func (scriptedAgentExecutor) Execute(context.Context, string, AgentToolCall) (ToolResultEnvelope, error) {
	return ToolResultEnvelope{OK: true, Data: json.RawMessage(`{"items":[]}`), Freshness: FreshnessLive}, nil
}

func TestAgentOrchestratorReplansAndStopsAtApproval(t *testing.T) {
	planner := &scriptedAgentPlanner{}
	orchestrator, err := NewAgentOrchestrator([]AgentCapability{
		{ID: "competition.search", Available: true, Lane: "public", Description: "搜索比赛"},
		{ID: "calendar.create", Available: true, Lane: "personal", Kind: "action", SideEffect: SideEffectProposal, Confirmation: ConfirmationAlways, RequiresConfirmation: true, Description: "创建日历草稿", Tags: []string{"安排"}},
	}, planner, scriptedAgentExecutor{}, AgentOrchestratorConfig{Clock: func() time.Time { return time.Unix(1, 0) }})
	require.NoError(t, err)
	result, err := orchestrator.Run(context.Background(), AgentRunInput{RunID: "run-1", Message: "找比赛并安排训练"})
	require.NoError(t, err)
	require.Equal(t, DecisionProposeAction, result.Decision.Type)
	require.Len(t, result.State.CompletedSteps, 1)
	require.Len(t, result.State.PendingActions, 1)
	require.Contains(t, result.Activities[0].Type, "goal.updated")
}

type observationDrivenPlanner struct{}

func (observationDrivenPlanner) Next(_ context.Context, state AgentRunState, _ []AgentCapability) (AgentDecision, error) {
	switch len(state.Observations) {
	case 0:
		return AgentDecision{Type: DecisionToolCall, ToolCall: &AgentToolCall{ID: "search", Capability: "competition.search", Arguments: json.RawMessage(`{"query":"算法比赛"}`)}}, nil
	case 1:
		if !strings.Contains(string(state.Observations[0].Result.Data), "candidate-a") {
			return AgentDecision{}, errors.New("search_observation_not_visible")
		}
		return AgentDecision{Type: DecisionToolCall, ToolCall: &AgentToolCall{ID: "details", Capability: "competition.details", Arguments: json.RawMessage(`{"competition_id":"candidate-a"}`)}}, nil
	case 2:
		return AgentDecision{Type: DecisionToolCall, ToolCall: &AgentToolCall{ID: "schedule", Capability: "schedule.free_windows", Arguments: json.RawMessage(`{"from":"2026-08-24T00:00:00Z","to":"2026-08-31T00:00:00Z"}`)}}, nil
	default:
		return AgentDecision{Type: DecisionRespond, FinalAnswer: "候选 A 已核对，并完成课程冲突检查。"}, nil
	}
}

type observationDrivenExecutor struct{}

func (observationDrivenExecutor) Execute(_ context.Context, _ string, call AgentToolCall) (ToolResultEnvelope, error) {
	switch call.Capability {
	case "competition.search":
		return ToolResultEnvelope{OK: true, Data: json.RawMessage(`{"items":[{"id":"candidate-a"}]}`), Freshness: FreshnessLive}, nil
	case "competition.details":
		return ToolResultEnvelope{OK: true, Data: json.RawMessage(`{"id":"candidate-a","deadline":"2026-09-10"}`), Freshness: FreshnessLive}, nil
	case "schedule.free_windows":
		return ToolResultEnvelope{OK: true, Data: json.RawMessage(`{"conflicts":[]}`), Freshness: FreshnessLive}, nil
	default:
		return ToolResultEnvelope{}, errors.New("unexpected_capability")
	}
}

func TestAgentOrchestratorUsesObservationsForDynamicReplan(t *testing.T) {
	orchestrator, err := NewAgentOrchestrator([]AgentCapability{
		{ID: "competition.search", Available: true, Lane: "public", Description: "检索公开比赛", Tags: []string{"比赛"}},
		{ID: "competition.details", Available: true, Lane: "public", Description: "读取比赛详情", Tags: []string{"比赛", "详情"}},
		{ID: "schedule.free_windows", Available: true, Lane: "personal", Description: "计算课程空闲时间", Tags: []string{"课程", "冲突"}},
	}, observationDrivenPlanner{}, observationDrivenExecutor{}, AgentOrchestratorConfig{Clock: func() time.Time { return time.Unix(1, 0) }})
	require.NoError(t, err)
	result, err := orchestrator.Run(context.Background(), AgentRunInput{RunID: "blackbox-replan", Message: "推荐一个比赛，但不要影响上课"})
	require.NoError(t, err)
	require.Equal(t, DecisionRespond, result.Decision.Type)
	require.Len(t, result.State.Observations, 3)
	require.GreaterOrEqual(t, result.State.PlanVersion, 4)
	require.GreaterOrEqual(t, countAgentActivities(result.Activities, "plan.revised"), 3)
}

func countAgentActivities(events []AgentActivityEvent, eventType string) int {
	count := 0
	for _, event := range events {
		if event.Type == eventType {
			count++
		}
	}
	return count
}

type mutatingGoalPlanner struct{}

func (mutatingGoalPlanner) Next(context.Context, AgentRunState, []AgentCapability) (AgentDecision, error) {
	return AgentDecision{Type: DecisionRespond, FinalAnswer: "不应改变题目", GoalUpdate: &GoalSpec{Objective: "改成另一个任务"}}, nil
}

func TestAgentOrchestratorDoesNotAllowPlannerToChangeObjective(t *testing.T) {
	orchestrator, err := NewAgentOrchestrator([]AgentCapability{{ID: "system.status", Available: true, Lane: "public", Description: "读取状态"}}, mutatingGoalPlanner{}, scriptedAgentExecutor{}, AgentOrchestratorConfig{})
	require.NoError(t, err)
	result, err := orchestrator.Run(context.Background(), AgentRunInput{RunID: "blackbox-goal", Message: "帮我看看比赛截止时间"})
	require.EqualError(t, err, "agent_goal_objective_immutable")
	require.Equal(t, "帮我看看比赛截止时间", result.State.Goal.Objective)
}

func TestAgentOrchestratorConstraintUpdateInvalidatesPendingActions(t *testing.T) {
	state := AgentRunState{Goal: GoalSpec{ActionIntent: "plan"}, PendingActions: []AgentActionProposal{{Action: "calendar.create"}}, ConstraintVersion: 2}
	orchestrator := &AgentOrchestrator{}
	require.NoError(t, orchestrator.UpdateConstraints(&state, []GoalConstraint{{Text: "周六不要安排", Hard: true, Source: "explicit"}}))
	require.Equal(t, 3, state.ConstraintVersion)
	require.Empty(t, state.PendingActions)
}
