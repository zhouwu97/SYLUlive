package ai

import (
	"context"
	"encoding/json"
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
	orchestrator, err := NewAgentOrchestrator([]AgentCapability{{ID: "competition.search", Available: true, Lane: "public", Description: "搜索比赛"}}, planner, scriptedAgentExecutor{}, AgentOrchestratorConfig{Clock: func() time.Time { return time.Unix(1, 0) }})
	require.NoError(t, err)
	result, err := orchestrator.Run(context.Background(), AgentRunInput{RunID: "run-1", Message: "找比赛并安排训练"})
	require.NoError(t, err)
	require.Equal(t, DecisionProposeAction, result.Decision.Type)
	require.Len(t, result.State.CompletedSteps, 1)
	require.Len(t, result.State.PendingActions, 1)
	require.Contains(t, result.Activities[0].Type, "goal.updated")
}

func TestAgentOrchestratorConstraintUpdateInvalidatesPendingActions(t *testing.T) {
	state := AgentRunState{Goal: GoalSpec{ActionIntent: "plan"}, PendingActions: []AgentActionProposal{{Action: "calendar.create"}}, ConstraintVersion: 2}
	orchestrator := &AgentOrchestrator{}
	require.NoError(t, orchestrator.UpdateConstraints(&state, []GoalConstraint{{Text: "周六不要安排", Hard: true, Source: "explicit"}}))
	require.Equal(t, 3, state.ConstraintVersion)
	require.Empty(t, state.PendingActions)
}
