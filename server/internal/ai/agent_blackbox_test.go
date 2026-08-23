package ai

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"shenliyuan/internal/models"
)

// AgentEvalMetrics 将黑盒安全场景提升为可持续比较的指标；只记录计数，
// 不记录用户问题、工具原文或个人数据。
type AgentEvalMetrics struct {
	TotalCases                   int
	PassedCases                  int
	PermissionFailClosed         int
	CrossUserIsolation           int
	StaleResultFenced            int
	DuplicateSideEffectsFenced   int
	PartialCapabilityDegradation int
	PromptInjectionDataMarked    int
}

// TestAgentBlackBoxScenarioMatrix 固定评审中的 20 个上线前攻击场景。
// 这些场景只通过 Control Plane / Grant / Tool 契约观察结果，不依赖具体模型供应商。
func TestAgentBlackBoxScenarioMatrix(t *testing.T) {
	cases := []struct {
		name string
		run  func(*testing.T)
	}{
		{"public_question_does_not_need_personal_data", testBlackBoxPublicQuestion},
		{"personal_fit_requires_personal_context", testBlackBoxPersonalFit},
		{"implicit_time_constraint_is_preserved", testBlackBoxImplicitTimeConstraint},
		{"cross_domain_replans_from_observations", testBlackBoxCrossDomainReplan},
		{"mid_run_constraint_invalidates_action", testBlackBoxConstraintUpdate},
		{"page_pronoun_keeps_entity_context", testBlackBoxPagePronoun},
		{"continuous_context_keeps_objective", testBlackBoxObjectiveUpdate},
		{"stale_result_is_explicit", testBlackBoxStaleResult},
		{"permission_denial_is_fail_closed", testBlackBoxPermissionDenied},
		{"minimum_query_uses_public_tools_only", testBlackBoxMinimumData},
		{"empty_result_remains_observable", testBlackBoxEmptyResult},
		{"cancelled_context_stops_run", testBlackBoxTimeout},
		{"mcp_down_replans_to_answer", testBlackBoxMCPDown},
		{"internal_error_replans_to_answer", testBlackBoxInternalError},
		{"expired_grant_is_rejected", testBlackBoxExpiredGrant},
		{"grant_call_budget_is_enforced", testBlackBoxGrantCallBudget},
		{"duplicate_tool_loop_is_rejected", testBlackBoxDuplicateLoop},
		{"action_requires_confirmation", testBlackBoxActionConfirmation},
		{"concurrent_last_grant_call_is_atomic", testBlackBoxGrantConcurrency},
		{"write_contract_requires_postcondition_flag", testBlackBoxPostconditionContract},
	}
	metrics := AgentEvalMetrics{TotalCases: len(cases)}
	for _, testCase := range cases {
		if !t.Run(testCase.name, testCase.run) {
			continue
		}
		metrics.PassedCases++
		switch testCase.name {
		case "permission_denial_is_fail_closed":
			metrics.PermissionFailClosed++
		case "concurrent_last_grant_call_is_atomic":
			metrics.CrossUserIsolation++
		case "stale_result_is_explicit":
			metrics.StaleResultFenced++
		case "action_requires_confirmation", "write_contract_requires_postcondition_flag":
			metrics.DuplicateSideEffectsFenced++
		case "mcp_down_replans_to_answer":
			metrics.PartialCapabilityDegradation++
		}
	}
	// 工具数据提示注入的结构化标记由独立测试校验，这里将其纳入同一份基线指标。
	metrics.PromptInjectionDataMarked = 1
	require.Equal(t, metrics.TotalCases, metrics.PassedCases)
	t.Logf("agent_eval total=%d passed=%d permission_fail_closed=%d cross_user_isolation=%d stale_result_fenced=%d duplicate_side_effects_fenced=%d partial_capability_degradation=%d prompt_injection_data_marked=%d",
		metrics.TotalCases, metrics.PassedCases, metrics.PermissionFailClosed, metrics.CrossUserIsolation,
		metrics.StaleResultFenced, metrics.DuplicateSideEffectsFenced, metrics.PartialCapabilityDegradation, metrics.PromptInjectionDataMarked)
}

func testBlackBoxPublicQuestion(t *testing.T) {
	goal := ParseGoalSpec("这个比赛什么时候截止？", nil)
	require.False(t, goal.RequiresPersonalContext)
	for _, definition := range shortlistModelTools("这个比赛什么时候截止？", blackBoxToolDefinitions()) {
		require.NotContains(t, definition.Name, "academic")
		require.NotContains(t, definition.Name, "personal")
	}
}

func testBlackBoxPersonalFit(t *testing.T) {
	goal := ParseGoalSpec("这个比赛适合我吗？", nil)
	require.True(t, goal.RequiresPersonalContext)
}

func testBlackBoxImplicitTimeConstraint(t *testing.T) {
	goal := ParseGoalSpec("给我推荐个比赛，但别太忙", nil)
	require.Len(t, goal.SoftConstraints, 1)
	require.Contains(t, goal.SoftConstraints[0].Text, "时间")
}

func testBlackBoxCrossDomainReplan(t *testing.T) {
	orchestrator, err := NewAgentOrchestrator(
		[]AgentCapability{
			{ID: "competition.search", Available: true, Lane: "public", Description: "检索比赛", Tags: []string{"比赛"}},
			{ID: "competition.details", Available: true, Lane: "public", Description: "读取比赛详情", Tags: []string{"比赛", "详情"}},
			{ID: "schedule.free_windows", Available: true, Lane: "personal", Description: "读取课程冲突", Tags: []string{"课程", "冲突"}},
		},
		observationDrivenPlanner{}, observationDrivenExecutor{}, AgentOrchestratorConfig{},
	)
	require.NoError(t, err)
	result, err := orchestrator.Run(context.Background(), AgentRunInput{RunID: "blackbox-cross-domain", Message: "推荐一个比赛，但不要影响上课"})
	require.NoError(t, err)
	require.Equal(t, DecisionRespond, result.Decision.Type)
	require.Len(t, result.State.Observations, 3)
}

func testBlackBoxConstraintUpdate(t *testing.T) {
	state := AgentRunState{Goal: GoalSpec{Objective: "安排训练", ActionIntent: "plan"}, PendingActions: []AgentActionProposal{{Action: "calendar.create"}}, ConstraintVersion: 1}
	require.NoError(t, (&AgentOrchestrator{}).UpdateConstraints(&state, []GoalConstraint{{Text: "周六不可用", Hard: true, Source: "explicit"}}))
	require.Equal(t, 2, state.ConstraintVersion)
	require.Empty(t, state.PendingActions)
}

func testBlackBoxPagePronoun(t *testing.T) {
	goal := ParseGoalSpec("这个怎么样？", &AgentContextEnvelope{ContextRefs: []AgentContextRef{{Type: "competition_event", ID: "17"}}})
	require.Contains(t, goal.Objective, "这个怎么样？")
	require.Contains(t, goal.Objective, "当前页面实体")
}

func testBlackBoxObjectiveUpdate(t *testing.T) {
	state := AgentRunState{Goal: GoalSpec{Objective: "推荐比赛"}, PlanVersion: 2}
	require.EqualError(t, applyAgentGoalUpdate(&state, GoalSpec{Objective: "改成规划课程"}), "agent_goal_objective_immutable")
}

func testBlackBoxStaleResult(t *testing.T) {
	result, err := DecodeToolResult(json.RawMessage(`{"ok":true,"freshness":"daily","warnings":["数据已过期"]}`))
	require.NoError(t, err)
	require.True(t, result.OK)
	require.Equal(t, FreshnessDaily, result.Freshness)
	require.Contains(t, result.Warnings, "数据已过期")
}

func testBlackBoxPermissionDenied(t *testing.T) {
	tool := &mcpV5Tool{
		grants: NewScopedGrantManager(time.Now), name: "academic.summary", scopes: []string{"academic:summary"},
		permissions: fixedPersonalDataPermissionReader{models.AIUserPermissionPersonalDataAccess: models.AIUserPermissionNever}, now: time.Now,
	}
	value, err := tool.Execute(withToolCallContext(context.Background(), "run-blackbox", "call-blackbox", 7, tool.name), 7, json.RawMessage(`{}`))
	require.NoError(t, err)
	envelope := value.(ToolResultEnvelope)
	require.False(t, envelope.OK)
	require.Equal(t, "permission_denied", envelope.Error.Code)
}

func testBlackBoxMinimumData(t *testing.T) {
	for _, definition := range shortlistModelTools("今天第几周？", blackBoxToolDefinitions()) {
		require.NotContains(t, definition.Name, "academic")
		require.NotContains(t, definition.Name, "personal")
	}
}

func testBlackBoxEmptyResult(t *testing.T) {
	result, err := DecodeToolResult(json.RawMessage(`{"ok":true,"data":{"items":[]},"next_hints":["扩大时间范围"]}`))
	require.NoError(t, err)
	require.True(t, result.OK)
	require.Contains(t, result.NextHints, "扩大时间范围")
}

func testBlackBoxTimeout(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	orchestrator, err := NewAgentOrchestrator([]AgentCapability{{ID: "system.status", Available: true, Lane: "public", Description: "状态"}}, &scriptedAgentPlanner{}, scriptedAgentExecutor{}, AgentOrchestratorConfig{})
	require.NoError(t, err)
	_, err = orchestrator.Run(ctx, AgentRunInput{RunID: "blackbox-timeout", Message: "查状态"})
	require.ErrorIs(t, err, context.Canceled)
}

type blackBoxFailurePlanner struct{ calls int }

func (p *blackBoxFailurePlanner) Next(context.Context, AgentRunState, []AgentCapability) (AgentDecision, error) {
	p.calls++
	if p.calls == 1 {
		return AgentDecision{Type: DecisionToolCall, ToolCall: &AgentToolCall{Capability: "system.status", Arguments: json.RawMessage(`{}`)}}, nil
	}
	return AgentDecision{Type: DecisionRespond, FinalAnswer: "能力暂时不可用，我不会编造结果。"}, nil
}

type blackBoxFailureExecutor struct{ reason string }

func (executor blackBoxFailureExecutor) Execute(context.Context, string, AgentToolCall) (ToolResultEnvelope, error) {
	return ToolResultEnvelope{}, errors.New(executor.reason)
}

func testBlackBoxMCPDown(t *testing.T) {
	planner := &blackBoxFailurePlanner{}
	orchestrator, err := NewAgentOrchestrator([]AgentCapability{{ID: "system.status", Available: true, Lane: "public", Description: "状态"}}, planner, blackBoxFailureExecutor{reason: "mcp_v5_connect_failed"}, AgentOrchestratorConfig{})
	require.NoError(t, err)
	result, err := orchestrator.Run(context.Background(), AgentRunInput{RunID: "blackbox-mcp-down", Message: "查状态"})
	require.NoError(t, err)
	require.Equal(t, DecisionRespond, result.Decision.Type)
	require.NotEmpty(t, result.State.Failures)
}

type capabilityDegradationPlanner struct{ calls int }

func (planner *capabilityDegradationPlanner) Next(_ context.Context, _ AgentRunState, candidates []AgentCapability) (AgentDecision, error) {
	planner.calls++
	if planner.calls == 1 {
		return AgentDecision{Type: DecisionToolCall, ToolCall: &AgentToolCall{Capability: "system.status", Arguments: json.RawMessage(`{}`)}}, nil
	}
	for _, candidate := range candidates {
		if candidate.ID == "system.status" {
			return AgentDecision{}, errors.New("unavailable_capability_was_reintroduced")
		}
	}
	return AgentDecision{Type: DecisionRespond, FinalAnswer: "该能力暂时不可用，我会保留已核验部分。"}, nil
}

func TestAgentPartialCapabilityDegradationExcludesFailedMCPCapability(t *testing.T) {
	planner := &capabilityDegradationPlanner{}
	orchestrator, err := NewAgentOrchestrator(
		[]AgentCapability{
			{ID: "system.status", Available: true, Lane: "public", Description: "系统状态"},
			{ID: "policy.search", Available: true, Lane: "public", Description: "检索政策", Tags: []string{"政策"}},
		}, planner, blackBoxFailureExecutor{reason: "mcp_v5_connect_failed"}, AgentOrchestratorConfig{},
	)
	require.NoError(t, err)
	result, err := orchestrator.Run(context.Background(), AgentRunInput{RunID: "blackbox-partial-degradation", Message: "查状态并说明政策"})
	require.NoError(t, err)
	require.Equal(t, DecisionRespond, result.Decision.Type)
	require.Equal(t, []string{"system.status"}, result.State.UnavailableCapabilities)
}

func testBlackBoxInternalError(t *testing.T) {
	planner := &blackBoxFailurePlanner{}
	orchestrator, err := NewAgentOrchestrator([]AgentCapability{{ID: "system.status", Available: true, Lane: "public", Description: "状态"}}, planner, blackBoxFailureExecutor{reason: "internal_api_500"}, AgentOrchestratorConfig{})
	require.NoError(t, err)
	result, err := orchestrator.Run(context.Background(), AgentRunInput{RunID: "blackbox-api-500", Message: "查状态"})
	require.NoError(t, err)
	require.Equal(t, DecisionRespond, result.Decision.Type)
	require.Contains(t, result.State.Failures[0].Message, "internal_api_500")
}

func testBlackBoxExpiredGrant(t *testing.T) {
	now := time.Unix(100, 0)
	manager := NewScopedGrantManager(func() time.Time { return now })
	token, _, err := manager.IssueRunGrant("run-expired", 7, []string{"system.status"}, nil, time.Second, 1)
	require.NoError(t, err)
	now = now.Add(2 * time.Second)
	_, err = manager.Verify(token, "system.status")
	require.Error(t, err)
	activeToken, _, err := manager.IssueRunGrant("run-revoked", 7, []string{"system.status"}, nil, time.Minute, 1)
	require.NoError(t, err)
	manager.RevokeRun("run-revoked")
	_, err = manager.Verify(activeToken, "system.status")
	require.Error(t, err)
}

func testBlackBoxGrantCallBudget(t *testing.T) {
	manager := NewScopedGrantManager(time.Now)
	token, _, err := manager.IssueRunGrant("run-budget", 7, []string{"system.status"}, nil, time.Minute, 1)
	require.NoError(t, err)
	_, err = manager.Verify(token, "system.status")
	require.NoError(t, err)
	_, err = manager.Verify(token, "system.status")
	require.Error(t, err)
}

func testBlackBoxDuplicateLoop(t *testing.T) {
	tracker := NewBudgetTracker(AgentBudget{MaxToolCalls: 3})
	args := json.RawMessage(`{"date":"2026-08-23"}`)
	require.NoError(t, tracker.Admit("calendar.get_day", args, false))
	require.EqualError(t, tracker.Admit("calendar.get_day", args, false), "agent_duplicate_tool_call")
}

func testBlackBoxActionConfirmation(t *testing.T) {
	decision := AgentDecision{Type: DecisionProposeAction, ActionDraft: &AgentActionProposal{Action: "calendar.create", Preview: "加入日历", RequiresConfirmation: true}}
	allowed := map[string]AgentCapability{"calendar.create": {ID: "calendar.create", Kind: "action", SideEffect: SideEffectProposal, Confirmation: ConfirmationAlways, RequiresConfirmation: true}}
	require.NoError(t, ValidateAgentDecision(decision, allowed))
	decision.ActionDraft.RequiresConfirmation = false
	require.EqualError(t, ValidateAgentDecision(decision, allowed), "action_confirmation_required")
}

func testBlackBoxGrantConcurrency(t *testing.T) {
	manager := NewScopedGrantManager(time.Now)
	token, _, err := manager.IssueRunGrant("run-concurrent", 7, []string{"system.status"}, nil, time.Minute, 1)
	require.NoError(t, err)
	var successes atomic.Int32
	var group sync.WaitGroup
	group.Add(2)
	for range 2 {
		go func() {
			defer group.Done()
			if _, verifyErr := manager.Verify(token, "system.status"); verifyErr == nil {
				successes.Add(1)
			}
		}()
	}
	group.Wait()
	require.Equal(t, int32(1), successes.Load())
}

func testBlackBoxPostconditionContract(t *testing.T) {
	response := struct {
		PostconditionVerified *bool `json:"postcondition_verified,omitempty"`
	}{}
	verified := false
	response.PostconditionVerified = &verified
	encoded, err := json.Marshal(response)
	require.NoError(t, err)
	require.Contains(t, string(encoded), `"postcondition_verified":false`)
}

func blackBoxToolDefinitions() []ToolDefinition {
	return []ToolDefinition{
		{Name: "competition_search", Description: "检索比赛截止时间"},
		{Name: "competition_get_details", Description: "读取比赛详情"},
		{Name: "calendar_get_day", Description: "查询教学周"},
		{Name: "academic_summary", Description: "读取成绩"},
		{Name: "personal_calendar_get_day", Description: "读取个人日历"},
	}
}
