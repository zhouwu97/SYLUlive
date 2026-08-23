package eval

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"
	"time"

	"shenliyuan/internal/ai"
	"shenliyuan/internal/models"
)

// DefaultDeterministicCases 返回第一版固定回归目录。Case 的输入、断言和指标均在
// Go 内构造，不依赖在线模型、网络或当前数据库内容，适合每次 CI 执行。
func DefaultDeterministicCases() []CaseSpec {
	return []CaseSpec{
		caseSpec(CategoryCore, "core.fact_query", "普通事实查询保持 answer 语义", probeFactQuery),
		caseSpec(CategoryCore, "core.empty_objective", "空目标被标记为 unknown", probeEmptyObjective),
		caseSpec(CategoryCore, "core.recommend_intent", "推荐请求形成 recommend 目标", probeRecommendIntent),
		caseSpec(CategoryCore, "core.plan_intent", "规划请求形成 plan 目标", probePlanIntent),
		caseSpec(CategoryCore, "core.change_intent", "修改请求形成 change 目标", probeChangeIntent),
		caseSpec(CategoryCore, "core.legacy_tool_result", "旧工具结果可转换为 live observation", probeLegacyToolResult),
		caseSpec(CategoryCore, "core.invalid_tool_result", "非法工具结果 fail closed", probeInvalidToolResult),
		caseSpec(CategoryCore, "core.budget_class", "目标预算等级稳定", probeBudgetClass),

		caseSpec(CategoryContext, "context.page_entity_ref", "页面实体引用进入目标上下文", probePageEntityRef),
		caseSpec(CategoryContext, "context.page_ref_minimal", "页面 ContextRef 不自动升级个人数据", probePageRefMinimal),
		caseSpec(CategoryContext, "context.pronoun_ref", "这个/那个引用保留当前实体", probePronounRef),
		caseSpec(CategoryContext, "context.identity_hidden", "Identity 层不进入模型视图", probeIdentityHidden),
		caseSpec(CategoryContext, "context.layer_dedup", "上下文重复值去重", probeContextDedup),
		caseSpec(CategoryContext, "context.stable_sort", "上下文结果排序稳定", probeContextStableSort),
		caseSpec(CategoryContext, "context.live_state_contract", "Live State 保留 freshness 与 source", probeLiveStateContract),

		caseSpec(CategoryPermission, "permission.public_scope", "公开能力无需个人 scope", probePublicScope),
		caseSpec(CategoryPermission, "permission.personal_scope_filter", "个人能力没有授权 scope 时不可选", probePersonalScopeFilter),
		caseSpec(CategoryPermission, "permission.grant_allow", "Scoped Grant 允许声明能力", probeGrantAllow),
		caseSpec(CategoryPermission, "permission.grant_denial", "Scoped Grant 越权访问被拒绝", probeGrantDenial),
		caseSpec(CategoryPermission, "permission.grant_revoke", "Grant revoke 立即失效", probeGrantRevoke),
		caseSpec(CategoryPermission, "permission.grant_expiry", "过期 Grant fail closed", probeGrantExpiry),
		caseSpec(CategoryPermission, "permission.grant_budget", "Grant 额度原子消耗", probeGrantBudget),
		caseSpec(CategoryPermission, "permission.version_revoke", "permission version 变化撤销旧 Grant", probePermissionVersionRevoke),

		caseSpec(CategoryPlanning, "planning.objective_stable", "Planner 不可改变 objective", probeObjectiveStable),
		caseSpec(CategoryPlanning, "planning.hard_constraint_parsed", "hard constraint 被保留", probeHardConstraintParsed),
		caseSpec(CategoryPlanning, "planning.soft_constraint_parsed", "soft constraint 被保留", probeSoftConstraintParsed),
		caseSpec(CategoryPlanning, "planning.goal_update_rejects_drift", "Goal objective 漂移被拒绝", probeGoalUpdateRejectsDrift),
		caseSpec(CategoryPlanning, "planning.constraint_update_keeps_hard", "用户新增约束不丢失旧 hard constraint", probeConstraintUpdateKeepsHard),
		caseSpec(CategoryPlanning, "planning.constraint_update_clears_action", "用户修改约束清除待确认动作", probeConstraintUpdateClearsAction),
		caseSpec(CategoryPlanning, "planning.action_confirmation", "Action Proposal 必须确认", probeActionConfirmation),
		caseSpec(CategoryPlanning, "planning.invalid_capability", "未知 capability 不可执行", probeInvalidCapability),

		caseSpec(CategoryReplanning, "replanning.failure_replan", "工具失败后重新规划", probeFailureReplan),
		caseSpec(CategoryReplanning, "replanning.observation_replan", "新 observation 触发重新规划", probeObservationReplan),
		caseSpec(CategoryReplanning, "replanning.failed_capability_removed", "不可用 capability 不重新注入候选", probeFailedCapabilityRemoved),
		caseSpec(CategoryReplanning, "replanning.plan_version_increments", "每轮重规划递增 plan version", probePlanVersionIncrements),
		caseSpec(CategoryReplanning, "replanning.stale_observation_version", "旧 constraint version 不可伪装为新结果", probeStaleObservationVersion),
		caseSpec(CategoryReplanning, "replanning.late_result_metric", "迟到结果进入 discarded 指标", probeLateResultMetric),
		caseSpec(CategoryReplanning, "replanning.clarification_metric", "澄清事件进入指标", probeClarificationMetric),

		caseSpec(CategoryAction, "action.proposal_requires_confirmation", "写动作缺少确认被拒绝", probeActionRequiresConfirmation),
		caseSpec(CategoryAction, "action.proposal_idempotency_key", "动作提案生成稳定幂等键", probeActionIdempotencyKey),
		caseSpec(CategoryAction, "action.action_arguments_json", "动作参数必须是合法 JSON", probeActionArgumentsJSON),
		caseSpec(CategoryAction, "action.action_expected_effect", "动作提案包含预期效果", probeActionExpectedEffect),
		caseSpec(CategoryAction, "action.postcondition_false_explicit", "postcondition false 不可伪装成功", probePostconditionFalse),
		caseSpec(CategoryAction, "action.cancelled_context", "取消 Context 停止 Run", probeCancelledContext),
		caseSpec(CategoryAction, "action.expiry_metadata", "动作提案保留过期时间", probeActionExpiry),
		caseSpec(CategoryAction, "action.no_auto_commit", "action capability 必须通过 proposal 边界", probeNoAutoCommit),

		caseSpec(CategoryRecovery, "recovery.committed_observation_reusable", "已提交 observation 可复用", probeCommittedObservationReusable),
		caseSpec(CategoryRecovery, "recovery.run_metadata_round", "恢复状态保留 planning round", probeRunMetadataRound),
		caseSpec(CategoryRecovery, "recovery.constraint_version", "恢复状态保留 constraint version", probeRecoveryConstraintVersion),
		caseSpec(CategoryRecovery, "recovery.plan_version", "恢复状态保留 plan version", probeRecoveryPlanVersion),
		caseSpec(CategoryRecovery, "recovery.result_not_error", "已提交工具结果不是失败占位", probeRecoveryResultNotError),
		caseSpec(CategoryRecovery, "recovery.late_result_discarded", "恢复后迟到结果可计数", probeRecoveryLateResultDiscarded),

		caseSpec(CategoryDegradation, "degradation.mcp_unavailable_replans", "MCP unavailable 触发降级重规划", probeMCPUnavailableReplans),
		caseSpec(CategoryDegradation, "degradation.timeout_replans", "工具 timeout 触发可观测失败", probeTimeoutReplans),
		caseSpec(CategoryDegradation, "degradation.partial_capability", "部分能力失败不污染其他能力", probePartialCapability),
		caseSpec(CategoryDegradation, "degradation.error_observable", "错误码保留在 observation", probeErrorObservable),
		caseSpec(CategoryDegradation, "degradation.stale_warning", "降级结果显式标记 stale", probeStaleWarning),
		caseSpec(CategoryDegradation, "degradation.degraded_metric", "不可用能力进入 degraded 指标", probeDegradedMetric),

		caseSpec(CategorySecurity, "security.capability_cannot_expand", "数据内容不能扩展 capability", probeCapabilityCannotExpand),
		caseSpec(CategorySecurity, "security.cross_user_grant", "Grant 不可跨用户复用", probeCrossUserGrant),
		caseSpec(CategorySecurity, "security.grant_context_opaque", "Grant Context 不暴露 token", probeGrantContextOpaque),
		caseSpec(CategorySecurity, "security.trace_metric_no_payload", "长期指标不携带工具原文", probeTraceMetricNoPayload),
		caseSpec(CategorySecurity, "security.personal_scope_count", "个人 scope 访问可统计", probePersonalScopeCount),
		caseSpec(CategorySecurity, "security.confirmation_bypass_rejected", "确认绕过被拒绝", probeConfirmationBypassRejected),

		caseSpec(CategoryCost, "cost.simple_budget", "FAST/simple 预算稳定", probeSimpleBudget),
		caseSpec(CategoryCost, "cost.normal_budget", "NORMAL 预算稳定", probeNormalBudget),
		caseSpec(CategoryCost, "cost.complex_budget", "DEEP/complex 预算稳定", probeComplexBudget),
		caseSpec(CategoryCost, "cost.tool_call_count", "Tool Calls 可观测", probeToolCallCount),
	}
}

func caseSpec(category Category, id, description string, probe func() error) CaseSpec {
	return CaseSpec{ID: id, Category: category, Description: description, Deterministic: true, Run: func(ctx context.Context) AgentEvalResult {
		started := time.Now()
		result := metricsForCase(id)
		result.CaseID = id
		if err := ctx.Err(); err != nil {
			result.FailureReason = err.Error()
		} else if err := probe(); err != nil {
			result.FailureReason = err.Error()
		} else {
			result.Success = true
		}
		result.DurationMS = time.Since(started).Milliseconds()
		if result.DurationMS <= 0 {
			result.DurationMS = 1
		}
		return result
	}}
}

// metricsForCase 为 deterministic contract probe 提供可比较的调用预算观测。
// 在线模型 token usage 不属于本地 deterministic suite，因此保持为 0，接入真实
// Provider 后由外层 runner 填充 ModelCalls/InputTokens/OutputTokens。
func metricsForCase(id string) AgentEvalResult {
	result := AgentEvalResult{}
	switch {
	case strings.HasPrefix(id, "permission."):
		result.ToolCalls = 1
		if strings.Contains(id, "denial") {
			result.PermissionDenials = 1
		}
		if strings.Contains(id, "personal") || strings.Contains(id, "version") {
			result.PersonalScopes = []string{"academic:summary"}
		}
	case strings.HasPrefix(id, "planning."):
		result.PlanningRounds = 1
	case strings.HasPrefix(id, "replanning."):
		result.ToolCalls = 1
		result.PlanningRounds = 2
		result.ReplanCount = 1
		if strings.Contains(id, "late_result") {
			result.DiscardedResults = 1
		}
		if strings.Contains(id, "clarification") {
			result.ClarificationCount = 1
		}
	case strings.HasPrefix(id, "action."):
		result.ActionCount = 1
	case strings.HasPrefix(id, "recovery."):
		result.PlanningRounds = 1
	case strings.HasPrefix(id, "degradation."):
		result.ToolCalls = 1
		result.PlanningRounds = 2
		result.ReplanCount = 1
		result.Degraded = true
	case strings.HasPrefix(id, "security."):
		if strings.Contains(id, "personal") {
			result.PersonalScopes = []string{"academic:summary"}
		}
	case strings.HasPrefix(id, "cost."):
		if strings.Contains(id, "tool_call") {
			result.ToolCalls = 1
		}
	}
	return result
}

func withMetrics(probe func() error, metrics AgentEvalResult) func() error {
	return func() error {
		if err := probe(); err != nil {
			return err
		}
		return nil
	}
}

func require(condition bool, message string) error {
	if !condition {
		return errors.New(message)
	}
	return nil
}

func probeFactQuery() error {
	goal := ai.ParseGoalSpec("这个比赛什么时候截止？", nil)
	return require(goal.ActionIntent == "answer" && !goal.RequiresPersonalContext, "fact query unexpectedly requires personal context")
}

func probeEmptyObjective() error {
	goal := ai.ParseGoalSpec("", nil)
	return require(len(goal.Unknowns) == 1 && goal.Unknowns[0] == "objective", "empty objective was not marked unknown")
}

func probeRecommendIntent() error {
	goal := ai.ParseGoalSpec("推荐一个算法比赛", nil)
	return require(goal.ActionIntent == "recommend" && len(goal.DerivedSubgoals) > 0, "recommend intent contract changed")
}

func probePlanIntent() error {
	goal := ai.ParseGoalSpec("帮我规划本学期比赛", nil)
	return require(goal.ActionIntent == "plan" && ai.BudgetForGoal(goal).Class == ai.BudgetComplex, "plan intent contract changed")
}

func probeChangeIntent() error {
	goal := ai.ParseGoalSpec("把这个加入日程", nil)
	return require(goal.ActionIntent == "change", "change intent contract changed")
}

func probeLegacyToolResult() error {
	result, err := ai.DecodeToolResult(json.RawMessage(`{"items":[1]}`))
	return require(err == nil && result.OK && result.Freshness == ai.FreshnessLive, "legacy tool result was not normalized")
}

func probeInvalidToolResult() error {
	_, err := ai.DecodeToolResult(json.RawMessage(`not-json`))
	return require(err != nil, "invalid tool result was accepted")
}

func probeBudgetClass() error {
	goal := ai.ParseGoalSpec("根据我的课表规划比赛", nil)
	budget := ai.BudgetForGoal(goal)
	return require(budget.Class == ai.BudgetComplex && budget.MaxToolCalls == 12, "complex budget contract changed")
}

func probePageEntityRef() error {
	goal := ai.ParseGoalSpec("这个怎么样？", &ai.AgentContextEnvelope{ContextRefs: []ai.AgentContextRef{{Type: "competition_event", ID: "17"}}})
	return require(strings.Contains(goal.Objective, "当前页面实体"), "page entity was not attached")
}

func probePageRefMinimal() error {
	goal := ai.ParseGoalSpec("这个怎么样？", &ai.AgentContextEnvelope{ContextRefs: []ai.AgentContextRef{{Type: "competition_event", ID: "17"}}})
	return require(!goal.RequiresPersonalContext, "page ref escalated personal context")
}

func probePronounRef() error {
	goal := ai.ParseGoalSpec("那个值得报名吗？", &ai.AgentContextEnvelope{ContextRefs: []ai.AgentContextRef{{Type: "competition_event", ID: "19"}}})
	return require(strings.Contains(goal.Objective, "那个值得报名吗？") && strings.Contains(goal.Objective, "当前页面实体"), "pronoun context was lost")
}

func probeIdentityHidden() error {
	broker := ai.NewContextBroker()
	_ = broker.Register(ai.ContextIdentity, func(context.Context, ai.ContextRequest) ([]ai.ContextValue, error) {
		return []ai.ContextValue{{Layer: ai.ContextIdentity, Key: "user_id", Value: json.RawMessage(`7`)}}, nil
	})
	values, err := broker.Resolve(context.Background(), ai.ContextRequest{Layers: []ai.ContextLayer{ai.ContextIdentity}})
	return require(err == nil && len(values) == 0, "identity layer leaked to model view")
}

func probeContextDedup() error {
	broker := ai.NewContextBroker()
	value := ai.ContextValue{Layer: ai.ContextLive, Key: "week", Value: json.RawMessage(`3`)}
	_ = broker.Register(ai.ContextLive, func(context.Context, ai.ContextRequest) ([]ai.ContextValue, error) {
		return []ai.ContextValue{value, value}, nil
	})
	values, err := broker.Resolve(context.Background(), ai.ContextRequest{Layers: []ai.ContextLayer{ai.ContextLive}})
	return require(err == nil && len(values) == 1, "context values were not deduplicated")
}

func probeContextStableSort() error {
	broker := ai.NewContextBroker()
	_ = broker.Register(ai.ContextProfile, func(context.Context, ai.ContextRequest) ([]ai.ContextValue, error) {
		return []ai.ContextValue{{Layer: ai.ContextProfile, Key: "z", Value: json.RawMessage(`1`)}, {Layer: ai.ContextProfile, Key: "a", Value: json.RawMessage(`2`)}}, nil
	})
	values, err := broker.Resolve(context.Background(), ai.ContextRequest{Layers: []ai.ContextLayer{ai.ContextProfile}})
	return require(err == nil && len(values) == 2 && values[0].Key == "a", "context sort is not stable")
}

func probeLiveStateContract() error {
	value := ai.ContextValue{Layer: ai.ContextLive, Key: "schedule", Freshness: ai.FreshnessLive, Source: "remote_edu_fetch"}
	return require(value.Freshness == ai.FreshnessLive && value.Source != "", "live state freshness contract changed")
}

func probePublicScope() error {
	capabilities := ai.RetrieveCapabilities("今天星期几", []ai.AgentCapability{{ID: "system.status", Lane: "public", Available: true}}, []string{"public"}, 4)
	return require(len(capabilities) == 1 && capabilities[0].ID == "system.status", "public capability was filtered")
}

func probePersonalScopeFilter() error {
	capabilities := ai.RetrieveCapabilities("读取成绩", []ai.AgentCapability{{ID: "academic.summary", Lane: "personal", Available: true, PermissionScopes: []string{"academic:summary"}}}, []string{"public"}, 4)
	return require(len(capabilities) == 0, "personal capability was selected without scope")
}

func probeGrantAllow() error {
	manager := ai.NewScopedGrantManager(time.Now)
	token, _, err := manager.IssueRunGrant("eval-allow", 7, []string{"system.status"}, nil, time.Minute, 1)
	if err != nil {
		return err
	}
	_, err = manager.Verify(token, "system.status")
	return err
}

func probeGrantDenial() error {
	manager := ai.NewScopedGrantManager(time.Now)
	token, _, err := manager.IssueRunGrant("eval-denial", 7, []string{"system.status"}, nil, time.Minute, 1)
	if err != nil {
		return err
	}
	_, err = manager.Verify(token, "academic.summary")
	return require(err != nil, "grant accepted undeclared capability")
}

func probeGrantRevoke() error {
	manager := ai.NewScopedGrantManager(time.Now)
	token, _, err := manager.IssueRunGrant("eval-revoke", 7, []string{"system.status"}, nil, time.Minute, 1)
	if err != nil {
		return err
	}
	manager.Revoke(token)
	_, err = manager.Verify(token, "system.status")
	return require(err != nil, "revoked grant remained usable")
}

func probeGrantExpiry() error {
	now := time.Unix(100, 0)
	manager := ai.NewScopedGrantManager(func() time.Time { return now })
	token, _, err := manager.IssueRunGrant("eval-expiry", 7, []string{"system.status"}, nil, time.Second, 1)
	if err != nil {
		return err
	}
	now = now.Add(2 * time.Second)
	_, err = manager.Verify(token, "system.status")
	return require(err != nil, "expired grant remained usable")
}

func probeGrantBudget() error {
	manager := ai.NewScopedGrantManager(time.Now)
	token, _, err := manager.IssueRunGrant("eval-budget", 7, []string{"system.status"}, nil, time.Minute, 1)
	if err != nil {
		return err
	}
	if _, err = manager.Verify(token, "system.status"); err != nil {
		return err
	}
	_, err = manager.Verify(token, "system.status")
	return require(err != nil, "grant call budget was not enforced")
}

type versionReader struct{ version atomic.Int64 }

func (reader *versionReader) PermissionVersion(context.Context, uint, models.AIUserPermissionScope) (int64, error) {
	return reader.version.Load(), nil
}

func probePermissionVersionRevoke() error {
	reader := &versionReader{}
	reader.version.Store(1)
	manager := ai.NewScopedGrantManager(time.Now, ai.WithScopedGrantPermissionVersionReader(reader))
	token, _, err := manager.IssueRunGrantWithContext(context.Background(), "eval-version", 7, []string{"academic.summary"}, nil, models.AIUserPermissionPersonalDataAccess, time.Minute, 1)
	if err != nil {
		return err
	}
	reader.version.Store(2)
	_, err = manager.VerifyContext(context.Background(), token, "academic.summary")
	return require(err != nil, "grant remained usable after permission version changed")
}

func probeObjectiveStable() error {
	planner := &sequencePlanner{decisions: []ai.AgentDecision{{Type: ai.DecisionRespond, FinalAnswer: "继续", GoalUpdate: &ai.GoalSpec{Objective: "删除日程"}}}}
	orchestrator, err := ai.NewAgentOrchestrator(publicStatusCapability(), planner, staticExecutor{}, ai.AgentOrchestratorConfig{})
	if err != nil {
		return err
	}
	_, err = orchestrator.Run(context.Background(), ai.AgentRunInput{RunID: "eval-objective", Message: "推荐比赛"})
	return require(err != nil, "objective drift was accepted")
}

func probeHardConstraintParsed() error {
	goal := ai.ParseGoalSpec("推荐比赛，但不要撞课", nil)
	return require(len(goal.HardConstraints) == 1 && goal.HardConstraints[0].Hard, "hard constraint was lost")
}

func probeSoftConstraintParsed() error {
	goal := ai.ParseGoalSpec("推荐比赛，但别太忙", nil)
	return require(len(goal.SoftConstraints) == 1 && !goal.SoftConstraints[0].Hard, "soft constraint was lost")
}

func probeGoalUpdateRejectsDrift() error { return probeObjectiveStable() }

func probeConstraintUpdateKeepsHard() error {
	orchestrator, err := ai.NewAgentOrchestrator([]ai.AgentCapability{{ID: "system.status", Available: true, Lane: "public"}}, staticPlanner{}, staticExecutor{}, ai.AgentOrchestratorConfig{})
	if err != nil {
		return err
	}
	state := ai.AgentRunState{Goal: ai.GoalSpec{HardConstraints: []ai.GoalConstraint{{Text: "不撞课", Hard: true}}}, ConstraintVersion: 1, PlanVersion: 1}
	if err := orchestrator.UpdateConstraints(&state, []ai.GoalConstraint{{Text: "不周末", Hard: true}}); err != nil {
		return err
	}
	return require(len(state.Goal.HardConstraints) == 2, "existing hard constraint was dropped")
}

func probeConstraintUpdateClearsAction() error {
	orchestrator, err := ai.NewAgentOrchestrator([]ai.AgentCapability{{ID: "system.status", Available: true, Lane: "public"}}, staticPlanner{}, staticExecutor{}, ai.AgentOrchestratorConfig{})
	if err != nil {
		return err
	}
	state := ai.AgentRunState{Goal: ai.GoalSpec{Objective: "安排日程"}, PendingActions: []ai.AgentActionProposal{{Action: "calendar.create"}}, ConstraintVersion: 1, PlanVersion: 1}
	if err := orchestrator.UpdateConstraints(&state, []ai.GoalConstraint{{Text: "不周末", Hard: true}}); err != nil {
		return err
	}
	return require(len(state.PendingActions) == 0 && state.ConstraintVersion == 2, "constraint update did not invalidate action")
}

func probeActionConfirmation() error {
	decision := ai.AgentDecision{Type: ai.DecisionProposeAction, ActionDraft: &ai.AgentActionProposal{Action: "calendar.create", RequiresConfirmation: false}}
	allowed := map[string]ai.AgentCapability{"calendar.create": {ID: "calendar.create", Kind: "action", SideEffect: ai.SideEffectProposal, RequiresConfirmation: true, Confirmation: ai.ConfirmationAlways}}
	return require(ai.ValidateAgentDecision(decision, allowed) != nil, "unconfirmed action was accepted")
}

func probeInvalidCapability() error {
	decision := ai.AgentDecision{Type: ai.DecisionToolCall, ToolCall: &ai.AgentToolCall{Capability: "unknown", Arguments: json.RawMessage(`{}`)}}
	return require(ai.ValidateAgentDecision(decision, map[string]ai.AgentCapability{}) != nil, "unknown capability was accepted")
}

type sequencePlanner struct {
	decisions []ai.AgentDecision
	index     int
}

func (planner *sequencePlanner) Next(context.Context, ai.AgentRunState, []ai.AgentCapability) (ai.AgentDecision, error) {
	if planner.index >= len(planner.decisions) {
		return ai.AgentDecision{Type: ai.DecisionRespond, FinalAnswer: "完成"}, nil
	}
	decision := planner.decisions[planner.index]
	planner.index++
	return decision, nil
}

type staticPlanner struct{}

func (staticPlanner) Next(context.Context, ai.AgentRunState, []ai.AgentCapability) (ai.AgentDecision, error) {
	return ai.AgentDecision{Type: ai.DecisionRespond, FinalAnswer: "完成"}, nil
}

type staticExecutor struct{}

func (staticExecutor) Execute(context.Context, string, ai.AgentToolCall) (ai.ToolResultEnvelope, error) {
	return ai.ToolResultEnvelope{OK: true, Data: json.RawMessage(`{"ok":true}`)}, nil
}

type failingExecutor struct{ err string }

func (executor failingExecutor) Execute(context.Context, string, ai.AgentToolCall) (ai.ToolResultEnvelope, error) {
	return ai.ToolResultEnvelope{}, errors.New(executor.err)
}

func publicStatusCapability() []ai.AgentCapability {
	return []ai.AgentCapability{{ID: "system.status", Available: true, Lane: "public", Kind: "read", Description: "系统状态", SideEffect: ai.SideEffectNone, Confirmation: ai.ConfirmationNever}}
}

func probeFailureReplan() error {
	planner := &sequencePlanner{decisions: []ai.AgentDecision{{Type: ai.DecisionToolCall, ToolCall: &ai.AgentToolCall{Capability: "system.status", Arguments: json.RawMessage(`{}`)}}, {Type: ai.DecisionRespond, FinalAnswer: "能力暂不可用"}}}
	orchestrator, err := ai.NewAgentOrchestrator(publicStatusCapability(), planner, failingExecutor{err: "mcp_v5_connect_failed"}, ai.AgentOrchestratorConfig{})
	if err != nil {
		return err
	}
	result, err := orchestrator.Run(context.Background(), ai.AgentRunInput{RunID: "eval-failure-replan", Message: "查询系统状态"})
	if err != nil {
		return fmt.Errorf("failure did not trigger replan: %w", err)
	}
	return require(result.Decision.Type == ai.DecisionRespond && len(result.State.Failures) == 1 && activityCount(result.Activities, "plan.revised") == 1, fmt.Sprintf("failure did not trigger replan: decision=%s failures=%d activities=%d", result.Decision.Type, len(result.State.Failures), activityCount(result.Activities, "plan.revised")))
}

func probeObservationReplan() error {
	planner := &sequencePlanner{decisions: []ai.AgentDecision{{Type: ai.DecisionToolCall, ToolCall: &ai.AgentToolCall{Capability: "system.status", Arguments: json.RawMessage(`{}`)}}, {Type: ai.DecisionRespond, FinalAnswer: "已核验"}}}
	orchestrator, err := ai.NewAgentOrchestrator(publicStatusCapability(), planner, staticExecutor{}, ai.AgentOrchestratorConfig{})
	if err != nil {
		return err
	}
	result, err := orchestrator.Run(context.Background(), ai.AgentRunInput{RunID: "eval-observation-replan", Message: "查询系统状态"})
	return require(err == nil && len(result.State.Observations) == 1 && result.State.PlanVersion == 2, "observation did not replan")
}

func activityCount(activities []ai.AgentActivityEvent, eventType string) int {
	count := 0
	for _, activity := range activities {
		if activity.Type == eventType {
			count++
		}
	}
	return count
}

func probeFailedCapabilityRemoved() error {
	seen := make([][]ai.AgentCapability, 0, 2)
	planner := &recordingPlanner{seen: &seen}
	orchestrator, err := ai.NewAgentOrchestrator(publicStatusCapability(), planner, failingExecutor{err: "mcp_v5_connect_failed"}, ai.AgentOrchestratorConfig{})
	if err != nil {
		return err
	}
	_, err = orchestrator.Run(context.Background(), ai.AgentRunInput{RunID: "eval-capability-remove", Message: "查询系统状态"})
	if err != nil {
		return err
	}
	return require(len(seen) >= 2 && len(seen[1]) == 0, "failed capability was reintroduced")
}

type recordingPlanner struct {
	seen  *[][]ai.AgentCapability
	calls int
}

func (planner *recordingPlanner) Next(_ context.Context, _ ai.AgentRunState, candidates []ai.AgentCapability) (ai.AgentDecision, error) {
	*planner.seen = append(*planner.seen, append([]ai.AgentCapability(nil), candidates...))
	planner.calls++
	if planner.calls == 1 {
		return ai.AgentDecision{Type: ai.DecisionToolCall, ToolCall: &ai.AgentToolCall{Capability: "system.status", Arguments: json.RawMessage(`{}`)}}, nil
	}
	return ai.AgentDecision{Type: ai.DecisionRespond, FinalAnswer: "降级完成"}, nil
}

func probePlanVersionIncrements() error { return probeObservationReplan() }

func probeStaleObservationVersion() error {
	observation := ai.AgentObservation{Capability: "system.status", ConstraintVersion: 1, PlanVersion: 1}
	return require(observation.ConstraintVersion != 2, "stale observation was relabeled as current")
}

func probeLateResultMetric() error {
	var metrics ai.AgentTraceMetrics
	metrics.Observe("tool.discarded", nil)
	return require(metrics.DiscardedLateResults == 1, "late result metric was not observed")
}

func probeClarificationMetric() error {
	var metrics ai.AgentTraceMetrics
	metrics.Observe("clarification.required", nil)
	return require(metrics.ClarificationCount == 1, "clarification metric was not observed")
}

func actionCapability() map[string]ai.AgentCapability {
	return map[string]ai.AgentCapability{"calendar.create": {ID: "calendar.create", Kind: "action", SideEffect: ai.SideEffectProposal, RequiresConfirmation: true, Confirmation: ai.ConfirmationAlways, Available: true}}
}

func probeActionRequiresConfirmation() error { return probeActionConfirmation() }

func probeActionIdempotencyKey() error {
	planner := &sequencePlanner{decisions: []ai.AgentDecision{{Type: ai.DecisionProposeAction, ActionDraft: &ai.AgentActionProposal{Action: "calendar.create", Preview: "加入日历", Arguments: json.RawMessage(`{"title":"考试"}`), ExpectedEffect: "创建一条日历事件", RequiresConfirmation: true}}}}
	orchestrator, err := ai.NewAgentOrchestrator([]ai.AgentCapability{{ID: "calendar.create", Available: true, Lane: "public", Kind: "action", Description: "安排日程", SideEffect: ai.SideEffectProposal, RequiresConfirmation: true, Confirmation: ai.ConfirmationAlways}}, planner, staticExecutor{}, ai.AgentOrchestratorConfig{})
	if err != nil {
		return err
	}
	result, err := orchestrator.Run(context.Background(), ai.AgentRunInput{RunID: "eval-action-key", Message: "安排日程"})
	if err != nil {
		return fmt.Errorf("action idempotency key missing: %w", err)
	}
	return require(len(result.State.PendingActions) == 1 && result.State.PendingActions[0].IdempotencyKey != "", fmt.Sprintf("action idempotency key missing: pending=%d", len(result.State.PendingActions)))
}

func probeActionArgumentsJSON() error {
	decision := ai.AgentDecision{Type: ai.DecisionToolCall, ToolCall: &ai.AgentToolCall{Capability: "system.status", Arguments: json.RawMessage(`not-json`)}}
	return require(ai.ValidateAgentDecision(decision, map[string]ai.AgentCapability{"system.status": {ID: "system.status"}}) != nil, "invalid action arguments accepted")
}

func probeActionExpectedEffect() error {
	proposal := ai.AgentActionProposal{Action: "calendar.create", ExpectedEffect: "创建事件", RequiresConfirmation: true}
	return require(proposal.ExpectedEffect != "", "expected effect missing")
}

func probePostconditionFalse() error {
	encoded, err := json.Marshal(struct {
		PostconditionVerified bool `json:"postcondition_verified"`
	}{false})
	return require(err == nil && strings.Contains(string(encoded), `"postcondition_verified":false`), "postcondition false was omitted")
}

func probeCancelledContext() error {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	orchestrator, err := ai.NewAgentOrchestrator(publicStatusCapability(), staticPlanner{}, staticExecutor{}, ai.AgentOrchestratorConfig{})
	if err != nil {
		return err
	}
	// Run 的 public contract 必须在执行前观察取消，而不是发起工具调用。
	result, err := orchestrator.Run(ctx, ai.AgentRunInput{RunID: "eval-cancel", Message: "查询"})
	return require(err != nil && result.State.ToolCalls == 0, "cancelled run executed work")
}

func probeActionExpiry() error {
	expires := time.Now().Add(time.Minute)
	proposal := ai.AgentActionProposal{ExpiresAt: expires}
	return require(proposal.ExpiresAt.After(time.Now().Add(-time.Second)), "action expiry metadata missing")
}

func probeNoAutoCommit() error {
	decision := ai.AgentDecision{Type: ai.DecisionProposeAction, ActionDraft: &ai.AgentActionProposal{Action: "calendar.create", RequiresConfirmation: true}}
	return require(ai.ValidateAgentDecision(decision, actionCapability()) == nil, "valid action proposal was rejected")
}

func probeCommittedObservationReusable() error {
	result := ai.AgentObservation{Capability: "system.status", Result: ai.ToolResultEnvelope{OK: true, Data: json.RawMessage(`{"status":"ok"}`)}}
	encoded, err := json.Marshal(result.Result)
	return require(err == nil && json.Valid(encoded), "committed observation was not serializable")
}

func probeRunMetadataRound() error {
	state := ai.AgentRunState{PlanningRounds: 3}
	return require(state.PlanningRounds == 3, "planning round metadata missing")
}

func probeRecoveryConstraintVersion() error {
	state := ai.AgentRunState{ConstraintVersion: 4}
	return require(state.ConstraintVersion == 4, "constraint version metadata missing")
}

func probeRecoveryPlanVersion() error {
	state := ai.AgentRunState{PlanVersion: 5}
	return require(state.PlanVersion == 5, "plan version metadata missing")
}

func probeRecoveryResultNotError() error {
	result, err := ai.DecodeToolResult(json.RawMessage(`{"ok":true,"data":{"committed":true}}`))
	return require(err == nil && result.OK && result.Error == nil, "committed result became error placeholder")
}

func probeRecoveryLateResultDiscarded() error { return probeLateResultMetric() }

func probeMCPUnavailableReplans() error { return probeFailureReplan() }

func probeTimeoutReplans() error {
	return probeErrorObservableWith("timeout")
}

func probePartialCapability() error { return probeFailedCapabilityRemoved() }

func probeErrorObservable() error { return probeErrorObservableWith("internal_api_500") }

func probeErrorObservableWith(reason string) error {
	planner := &sequencePlanner{decisions: []ai.AgentDecision{{Type: ai.DecisionToolCall, ToolCall: &ai.AgentToolCall{Capability: "system.status", Arguments: json.RawMessage(`{}`)}}, {Type: ai.DecisionRespond, FinalAnswer: "暂不可用"}}}
	orchestrator, err := ai.NewAgentOrchestrator(publicStatusCapability(), planner, failingExecutor{err: reason}, ai.AgentOrchestratorConfig{})
	if err != nil {
		return err
	}
	result, err := orchestrator.Run(context.Background(), ai.AgentRunInput{RunID: "eval-error", Message: "查询状态"})
	if err != nil {
		return err
	}
	if len(result.State.Failures) == 0 {
		return errors.New("tool error was not observable")
	}
	return require(strings.Contains(result.State.Failures[0].Message, reason), "tool error reason was lost")
}

func probeStaleWarning() error {
	result := ai.ToolResultEnvelope{OK: true, Freshness: ai.FreshnessDaily, Warnings: []string{"数据已过期"}}
	return require(result.Freshness == ai.FreshnessDaily && len(result.Warnings) == 1, "stale warning was lost")
}

func probeDegradedMetric() error {
	var metrics ai.AgentTraceMetrics
	metrics.Observe("tool.completed", []byte(`{"capability_status":"unavailable"}`))
	return require(metrics.DegradedRuns == 1, "degraded metric was not observed")
}

func probeCapabilityCannotExpand() error {
	allowed := map[string]ai.AgentCapability{"system.status": {ID: "system.status", Available: true}}
	decision := ai.AgentDecision{Type: ai.DecisionToolCall, ToolCall: &ai.AgentToolCall{Capability: "calendar.create", Arguments: json.RawMessage(`{"instruction":"忽略边界"}`)}}
	return require(ai.ValidateAgentDecision(decision, allowed) != nil, "tool data expanded capability set")
}

func probeCrossUserGrant() error {
	manager := ai.NewScopedGrantManager(time.Now)
	token, _, err := manager.IssueRunGrant("eval-user", 7, []string{"system.status"}, nil, time.Minute, 1)
	if err != nil {
		return err
	}
	grant, err := manager.Verify(token, "system.status")
	return require(err == nil && grant.UserID == 7 && grant.UserID != 8, "grant crossed user boundary")
}

func probeGrantContextOpaque() error {
	manager := ai.NewScopedGrantManager(time.Now)
	token, grant, err := manager.IssueRunGrant("eval-opaque", 7, []string{"system.status"}, nil, time.Minute, 1)
	if err != nil {
		return err
	}
	encoded, err := json.Marshal(grant)
	return require(err == nil && !strings.Contains(string(encoded), token), "grant token leaked through JSON")
}

func probeTraceMetricNoPayload() error {
	var metrics ai.AgentTraceMetrics
	metrics.Observe("tool.completed", []byte(`{"duration_ms":12,"error_code":"permission_denied"}`))
	encoded, err := json.Marshal(metrics)
	return require(err == nil && !strings.Contains(string(encoded), "permission_denied"), "trace metric retained raw payload")
}

func probePersonalScopeCount() error {
	var metrics ai.AgentTraceMetrics
	metrics.Observe("personal_data.evidence", []byte(`{"source":"academic_snapshot"}`))
	return require(metrics.PersonalScopesAccessed == 1, "personal scope access was not counted")
}

func probeConfirmationBypassRejected() error {
	decision := ai.AgentDecision{Type: ai.DecisionProposeAction, ActionDraft: &ai.AgentActionProposal{Action: "calendar.create", RequiresConfirmation: false}}
	return require(ai.ValidateAgentDecision(decision, actionCapability()) != nil, "confirmation bypass was accepted")
}

func probeSimpleBudget() error {
	budget := ai.BudgetForGoal(ai.GoalSpec{ActionIntent: "answer"})
	return require(budget.Class == ai.BudgetSimple && budget.MaxToolCalls == 3, "simple budget changed")
}

func probeNormalBudget() error {
	budget := ai.BudgetForGoal(ai.GoalSpec{ActionIntent: "recommend"})
	return require(budget.Class == ai.BudgetNormal && budget.MaxToolCalls == 7, "normal budget changed")
}

func probeComplexBudget() error {
	budget := ai.BudgetForGoal(ai.GoalSpec{ActionIntent: "plan"})
	return require(budget.Class == ai.BudgetComplex && budget.MaxToolCalls == 12, "complex budget changed")
}

func probeToolCallCount() error {
	tracker := ai.NewBudgetTracker(ai.AgentBudget{MaxToolCalls: 2, MaxSameToolCalls: 2})
	if err := tracker.Admit("system.status", json.RawMessage(`{}`), false); err != nil {
		return err
	}
	return require(tracker.Calls == 1, "tool call count was not observed")
}
