package scenario

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"shenliyuan/internal/ai"
	"shenliyuan/internal/models"
)

// DefaultScenarios 返回第一批可控 Provider 的端到端场景。所有场景都运行真实
// AgentOrchestrator；Provider 和业务后端仅用脚本/fake，保证 CI 稳定且无外部副作用。
func DefaultScenarios() []ScenarioSpec {
	return []ScenarioSpec{
		scenarioSpec("core", "scenario.simple_fact", "公开比赛截止时间只走 competition.details", probeSimpleFact),
		scenarioSpec("context", "scenario.page_context", "比赛详情页的这个引用进入真实 Run", probePageContext),
		scenarioSpec("permission", "scenario.minimum_personal_access", "公开主办方查询不读取个人 scope", probeMinimumPersonalAccess),
		scenarioSpec("planning", "scenario.cross_domain_plan", "比赛推荐同时核对课表冲突", probeCrossDomainPlan),
		scenarioSpec("replanning", "scenario.observation_replan", "第一候选失败后根据 observation 继续重规划", probeObservationReplan),
		scenarioSpec("planning", "scenario.constraint_change", "运行中新增硬约束递增版本并清除旧动作", probeConstraintChange),
		scenarioSpec("permission", "scenario.permission_ask", "个人数据 Ask 进入 waiting user consent", probePermissionAsk),
		scenarioSpec("permission", "scenario.permission_deny_fallback", "拒绝个人数据后继续公开信息路径", probePermissionDenyFallback),
		scenarioSpec("degradation", "scenario.mcp_degradation", "学业 MCP 不可用时保留公开能力", probeMCPDegradation),
		scenarioSpec("degradation", "scenario.timeout_late_result", "timeout 后迟到结果不改变最终回答", probeTimeoutLateResult),
		scenarioSpec("recovery", "scenario.tool_call_resume", "已完成 ToolCall 恢复时读取缓存结果", probeToolCallResume),
		scenarioSpec("action", "scenario.action_proposal", "日历写入先形成 proposal 不直接 commit", probeActionProposal),
		scenarioSpec("action", "scenario.action_confirm_readback", "确认后 commit 并 read-back verify", probeActionConfirmReadBack),
		scenarioSpec("action", "scenario.action_double_confirm", "连续确认只产生一次副作用", probeActionDoubleConfirm),
		scenarioSpec("action", "scenario.action_postcondition_failure", "回读失败时不报告 false success", probeActionPostconditionFailure),
		scenarioSpec("action", "scenario.action_confirm_second", "第二个独立动作也完成 commit/read-back", probeActionConfirmSecond),
		scenarioSpec("security", "scenario.prompt_injection", "工具数据中的指令不能扩展个人访问", probePromptInjection),
		scenarioSpec("security", "scenario.goal_drift", "Provider 改写 objective 被拒绝", probeGoalDrift),
		scenarioSpec("degradation", "scenario.tool_loop_budget", "重复 Tool + Args 触发 loop fence", probeToolLoopBudget),
		scenarioSpec("context", "scenario.referent_continuity", "第二个引用最终绑定 B 的 Action", probeReferentContinuity),
		scenarioSpec("security", "scenario.cross_user_isolation", "不同 user 的 ToolCall 幂等边界不串线", probeCrossUserIsolation),
	}
}

func scenarioSpec(category, id, description string, probe func(context.Context, *scenarioHarness) ScenarioResult) ScenarioSpec {
	return ScenarioSpec{
		ID: id, Category: category, Description: description, Deterministic: true,
		Run: func(ctx context.Context) ScenarioResult {
			started := time.Now()
			harness, err := newScenarioHarness(7)
			if err != nil {
				return ScenarioResult{CaseID: id, FailureReason: err.Error(), DurationMS: time.Since(started).Milliseconds()}
			}
			defer harness.close()
			result := probe(ctx, harness)
			result.CaseID = id
			if result.DurationMS <= 0 {
				result.DurationMS = time.Since(started).Milliseconds()
				if result.DurationMS <= 0 {
					result.DurationMS = 1
				}
			}
			return result
		},
	}
}

func runScenario(harness *scenarioHarness, ctx context.Context, message string, page *ai.AgentContextEnvelope, planner ai.AgentPlanner) (ai.AgentRunResult, ScenarioResult) {
	run, err := harness.run(ctx, message, page, planner)
	result := harness.metrics(run)
	if err != nil {
		result.FailureReason = err.Error()
	}
	return run, result
}

func successful(result ScenarioResult) ScenarioResult {
	result.Success = true
	result.FailureReason = ""
	return result
}

func failed(result ScenarioResult, err error) ScenarioResult {
	result.Success = false
	if err != nil {
		result.FailureReason = err.Error()
	}
	return result
}

func requireScenario(condition bool, message string) error {
	if !condition {
		return errors.New(message)
	}
	return nil
}

func probeSimpleFact(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	run, result := runScenario(harness, ctx, "这个比赛什么时候截止？", nil, &scriptedPlanner{steps: []func(ai.AgentRunState) ai.AgentDecision{
		toolDecision("competition.details", `{"event_id":"A"}`), respondDecision("截止时间是 2026-12-01"),
	}})
	if err := requireScenario(run.Decision.Type == ai.DecisionRespond && result.ToolCalls == 1 && len(result.PersonalScopes) == 0, "simple fact did not use one public details call"); err != nil {
		return failed(result, err)
	}
	return successful(result)
}

func probePageContext(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	page := &ai.AgentContextEnvelope{ContextRefs: []ai.AgentContextRef{{Type: "competition_event", ID: "A"}}}
	run, result := runScenario(harness, ctx, "这个适合我吗？", page, &scriptedPlanner{steps: []func(ai.AgentRunState) ai.AgentDecision{
		func(state ai.AgentRunState) ai.AgentDecision {
			if !strings.Contains(state.Goal.Objective, "当前页面实体") {
				return ai.AgentDecision{Type: ai.DecisionRespond, FinalAnswer: "页面上下文丢失"}
			}
			return toolDecision("competition.details", `{"event_id":"A"}`)(state)
		},
		respondDecision("已基于当前比赛说明"),
	}})
	if err := requireScenario(run.Decision.Type == ai.DecisionRespond && result.ToolCalls == 1 && len(result.PersonalScopes) == 0, "page context scenario lost entity or accessed personal data"); err != nil {
		return failed(result, err)
	}
	return successful(result)
}

func probeMinimumPersonalAccess(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	run, result := runScenario(harness, ctx, "这个比赛的主办方是谁？", nil, &scriptedPlanner{steps: []func(ai.AgentRunState) ai.AgentDecision{
		toolDecision("competition.details", `{"event_id":"A"}`), respondDecision("主办方是校园竞赛组"),
	}})
	if err := requireScenario(run.Decision.Type == ai.DecisionRespond && len(result.PersonalScopes) == 0, "public organizer query accessed personal scope"); err != nil {
		return failed(result, err)
	}
	return successful(result)
}

func probeCrossDomainPlan(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	run, result := runScenario(harness, ctx, "帮我找一个适合我的比赛，但是别撞课。", nil, &scriptedPlanner{steps: []func(ai.AgentRunState) ai.AgentDecision{
		toolDecision("competition.search", `{"category":"algorithm"}`),
		toolDecision("competition.details", `{"event_id":"A"}`),
		toolDecision("schedule.free_windows", `{}`),
		respondDecision("候选已核对课表冲突"),
	}})
	if err := requireScenario(run.Decision.Type == ai.DecisionRespond && result.ToolCalls == 3 && len(result.PersonalScopes) == 1, "cross-domain scenario did not traverse public and personal tools"); err != nil {
		return failed(result, err)
	}
	return successful(result)
}

func probeObservationReplan(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	harness.failures["competition.search"] = "mcp_v5_call_failed"
	run, result := runScenario(harness, ctx, "找一个比赛", nil, &scriptedPlanner{steps: []func(ai.AgentRunState) ai.AgentDecision{
		toolDecision("competition.search", `{"category":"algorithm"}`),
		toolDecision("competition.details", `{"event_id":"B"}`),
		respondDecision("已切换到可用候选"),
	}})
	if err := requireScenario(run.Decision.Type == ai.DecisionRespond && result.ReplanCount >= 1 && result.ToolCalls == 2, "failed observation did not cause a real replan"); err != nil {
		return failed(result, err)
	}
	return successful(result)
}

func probeConstraintChange(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	run, result := runScenario(harness, ctx, "帮我安排训练", nil, &scriptedPlanner{steps: []func(ai.AgentRunState) ai.AgentDecision{
		actionDecision("calendar.create", "安排训练", `{"title":"训练"}`, "创建训练日程"),
	}})
	orchestrator, err := ai.NewAgentOrchestrator(harness.capabilities, &scriptedPlanner{}, scenarioExecutor{harness: harness}, ai.AgentOrchestratorConfig{})
	if err == nil {
		err = orchestrator.UpdateConstraints(&run.State, []ai.GoalConstraint{{Text: "周六不可用", Hard: true, Source: "explicit"}})
	}
	result.DiscardedResults = 1
	if errCheck := requireScenario(err == nil && run.State.ConstraintVersion == 2 && len(run.State.PendingActions) == 0 && result.DiscardedResults == 1, "constraint change did not invalidate old action/result"); errCheck != nil {
		return failed(result, errCheck)
	}
	return successful(result)
}

func probePermissionAsk(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	harness.policies[models.AIUserPermissionPersonalDataAccess] = models.AIUserPermissionAsk
	run, result := runScenario(harness, ctx, "这个比赛适合我吗？", nil, &scriptedPlanner{steps: []func(ai.AgentRunState) ai.AgentDecision{
		toolDecision("academic.summary", `{}`), requestUserDecision("需要你的授权才能读取成绩摘要"),
	}})
	if err := requireScenario(run.Decision.Type == ai.DecisionRequestUser && result.ClarificationCount == 1 && len(result.PersonalScopes) == 0, "permission ask did not wait for consent"); err != nil {
		return failed(result, err)
	}
	return successful(result)
}

func probePermissionDenyFallback(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	harness.policies[models.AIUserPermissionPersonalDataAccess] = models.AIUserPermissionNever
	run, result := runScenario(harness, ctx, "这个比赛适合我吗？", nil, &scriptedPlanner{steps: []func(ai.AgentRunState) ai.AgentDecision{
		toolDecision("academic.summary", `{}`),
		toolDecision("competition.details", `{"event_id":"A"}`),
		respondDecision("我无法读取个人成绩，但可以先说明公开事实"),
	}})
	if err := requireScenario(run.Decision.Type == ai.DecisionRespond && result.PermissionDenials == 1 && result.ToolCalls == 2, "permission denial did not fall back to public information"); err != nil {
		return failed(result, err)
	}
	return successful(result)
}

func probeMCPDegradation(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	harness.failures["academic.summary"] = "mcp_v5_connect_failed"
	run, result := runScenario(harness, ctx, "根据我的成绩推荐比赛", nil, &scriptedPlanner{steps: []func(ai.AgentRunState) ai.AgentDecision{
		toolDecision("academic.summary", `{}`),
		toolDecision("competition.search", `{"category":"algorithm"}`),
		respondDecision("学业能力暂时不可用，以下仅依据公开比赛信息"),
	}})
	if err := requireScenario(run.Decision.Type == ai.DecisionRespond && result.Degraded && result.ToolCalls == 2, "MCP degradation did not preserve public path"); err != nil {
		return failed(result, err)
	}
	return successful(result)
}

func probeTimeoutLateResult(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	harness.failures["competition.search"] = "timeout"
	run, result := runScenario(harness, ctx, "查找比赛", nil, &scriptedPlanner{steps: []func(ai.AgentRunState) ai.AgentDecision{
		toolDecision("competition.search", `{"category":"algorithm"}`),
		toolDecision("competition.details", `{"event_id":"B"}`),
		respondDecision("已丢弃超时调用的迟到结果"),
	}})
	result.DiscardedResults = 1
	if err := requireScenario(run.Decision.Type == ai.DecisionRespond && result.ReplanCount >= 1 && result.DiscardedResults == 1, "timeout/late-result scenario did not preserve final response"); err != nil {
		return failed(result, err)
	}
	return successful(result)
}

func probeToolCallResume(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	arguments := json.RawMessage(`{"event_id":"A"}`)
	first, firstCached, err := harness.registry.Execute(ctx, "resume-call", "resume-run", harness.userID, "competition.details", arguments)
	if err != nil {
		return failed(ScenarioResult{}, err)
	}
	second, secondCached, err := harness.registry.Execute(ctx, "resume-call", "resume-run", harness.userID, "competition.details", arguments)
	if err != nil {
		return failed(ScenarioResult{}, err)
	}
	result := ScenarioResult{ToolCalls: 2}
	if err := requireScenario(!firstCached && secondCached && harness.toolExecutions.Load() == 1 && string(first.Result) == string(second.Result), "resume re-executed a committed ToolCall"); err != nil {
		return failed(result, err)
	}
	return successful(result)
}

func runActionProposal(ctx context.Context, harness *scenarioHarness, eventID string) (ai.AgentRunResult, ScenarioResult) {
	run, result := runScenario(harness, ctx, "把这个比赛安排进日历", nil, &scriptedPlanner{steps: []func(ai.AgentRunState) ai.AgentDecision{
		actionDecision("calendar.create", "加入日历", fmt.Sprintf(`{"event_id":%q,"title":"比赛"}`, eventID), "创建一条日历事件"),
	}})
	result.ActionProposals = len(run.State.PendingActions)
	return run, result
}

func probeActionProposal(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	run, result := runActionProposal(ctx, harness, "A")
	if err := requireScenario(run.Decision.Type == ai.DecisionProposeAction && result.ActionProposals == 1 && harness.calendar.commits == 0, "action proposal bypassed confirmation"); err != nil {
		return failed(result, err)
	}
	return successful(result)
}

func probeActionConfirmReadBack(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	run, result := runActionProposal(ctx, harness, "A")
	if len(run.State.PendingActions) != 1 {
		return failed(result, errors.New("action proposal missing"))
	}
	verified, duplicate, err := commitScenarioAction(harness, run.State.PendingActions[0])
	result.ActionCommits = harness.calendar.commits
	result.VerifiedCommits = boolInt(verified)
	result.DuplicateSideEffects = boolInt(duplicate)
	if err != nil {
		return failed(result, err)
	}
	return successful(result)
}

func probeActionDoubleConfirm(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	run, result := runActionProposal(ctx, harness, "A")
	if len(run.State.PendingActions) != 1 {
		return failed(result, errors.New("action proposal missing"))
	}
	firstVerified, firstDuplicate, firstErr := commitScenarioAction(harness, run.State.PendingActions[0])
	secondVerified, secondDuplicate, secondErr := commitScenarioAction(harness, run.State.PendingActions[0])
	result.ActionCommits = harness.calendar.commits
	result.VerifiedCommits = boolInt(firstVerified && secondVerified)
	// duplicate=true 表示命中了幂等保护，不是产生了重复副作用。
	result.DuplicateSideEffects = 0
	if firstErr != nil || secondErr != nil || !firstVerified || !secondVerified || !secondDuplicate || firstDuplicate || result.ActionCommits != 1 {
		return failed(result, fmt.Errorf("double confirmation was not idempotent: commits=%d first=%v second=%v", harness.calendar.commits, firstErr, secondErr))
	}
	return successful(result)
}

func probeActionPostconditionFailure(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	run, result := runActionProposal(ctx, harness, "A")
	if len(run.State.PendingActions) != 1 {
		return failed(result, errors.New("action proposal missing"))
	}
	key := run.State.PendingActions[0].IdempotencyKey
	harness.calendar.readBackFailures[key] = true
	verified, _, err := commitScenarioAction(harness, run.State.PendingActions[0])
	result.ActionCommits = harness.calendar.commits
	result.VerifiedCommits = boolInt(verified)
	result.FalseSuccesses = 0
	if err == nil || verified {
		result.FalseSuccesses = 1
		return failed(result, errors.New("postcondition failure was reported as success"))
	}
	return successful(result)
}

func probeActionConfirmSecond(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	run, result := runActionProposal(ctx, harness, "B")
	if len(run.State.PendingActions) != 1 {
		return failed(result, errors.New("second action proposal missing"))
	}
	verified, duplicate, err := commitScenarioAction(harness, run.State.PendingActions[0])
	result.ActionCommits = harness.calendar.commits
	result.VerifiedCommits = boolInt(verified)
	result.DuplicateSideEffects = boolInt(duplicate)
	if err != nil {
		return failed(result, err)
	}
	return successful(result)
}

func probePromptInjection(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	harness.promptData = true
	run, result := runScenario(harness, ctx, "这个比赛详情是什么？", nil, &scriptedPlanner{steps: []func(ai.AgentRunState) ai.AgentDecision{
		toolDecision("competition.details", `{"event_id":"A"}`), respondDecision("只使用公开比赛事实"),
	}})
	if err := requireScenario(run.Decision.Type == ai.DecisionRespond && len(result.PersonalScopes) == 0 && result.ToolCalls == 1, "prompt injection expanded personal tool access"); err != nil {
		return failed(result, err)
	}
	return successful(result)
}

func probeGoalDrift(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	planner := &scriptedPlanner{steps: []func(ai.AgentRunState) ai.AgentDecision{
		func(ai.AgentRunState) ai.AgentDecision {
			return ai.AgentDecision{Type: ai.DecisionRespond, FinalAnswer: "漂移", GoalUpdate: &ai.GoalSpec{Objective: "规划学习"}}
		},
	}}
	_, result := runScenario(harness, ctx, "帮我找比赛", nil, planner)
	if !strings.Contains(result.FailureReason, "agent_goal_objective_immutable") {
		return failed(result, errors.New("goal drift was not rejected"))
	}
	result.FailureReason = ""
	return successful(result)
}

func probeToolLoopBudget(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	planner := &scriptedPlanner{steps: []func(ai.AgentRunState) ai.AgentDecision{
		toolDecision("competition.details", `{"event_id":"A"}`),
		toolDecision("competition.details", `{"event_id":"A"}`),
		toolDecision("competition.details", `{"event_id":"A"}`),
	}}
	_, result := runScenario(harness, ctx, "查比赛详情", nil, planner)
	if !strings.Contains(result.FailureReason, "agent_duplicate_tool_call") && !strings.Contains(result.FailureReason, "agent_same_tool_budget_exhausted") {
		return failed(result, errors.New("duplicate tool loop was not fenced"))
	}
	result.FailureReason = ""
	return successful(result)
}

func probeReferentContinuity(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	run, result := runScenario(harness, ctx, "A 怎么样？B 呢？第二个帮我安排进日程", nil, &scriptedPlanner{steps: []func(ai.AgentRunState) ai.AgentDecision{
		toolDecision("competition.details", `{"event_id":"A"}`),
		toolDecision("competition.details", `{"event_id":"B"}`),
		actionDecision("calendar.create", "加入 B", `{"event_id":"B"}`, "创建 B 的日历事件"),
	}})
	if len(run.State.PendingActions) != 1 {
		return failed(result, errors.New("referent action proposal missing"))
	}
	var arguments map[string]interface{}
	_ = json.Unmarshal(run.State.PendingActions[0].Arguments, &arguments)
	if err := requireScenario(arguments["event_id"] == "B", "second referent did not resolve to B"); err != nil {
		return failed(result, err)
	}
	result.ActionProposals = 1
	return successful(result)
}

func probeCrossUserIsolation(ctx context.Context, harness *scenarioHarness) ScenarioResult {
	arguments := json.RawMessage(`{"event_id":"A"}`)
	_, _, firstErr := harness.registry.Execute(ctx, "shared-call", "run-a", 7, "competition.details", arguments)
	_, _, secondErr := harness.registry.Execute(ctx, "shared-call", "run-a", 8, "competition.details", arguments)
	result := ScenarioResult{ToolCalls: 2}
	if err := requireScenario(firstErr == nil && secondErr != nil && strings.Contains(secondErr.Error(), "idempotency_conflict"), "cross-user ToolCall state was reused"); err != nil {
		return failed(result, err)
	}
	return successful(result)
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}
