// Package scenario 提供 Agent Regression Suite v1.1 的端到端语义场景。
//
// 场景可以使用 fake Provider 和 fake 外部业务仓库，但执行链必须经过真实的
// AgentOrchestrator、Capability selection、ToolRegistry、Observation 和 Replan。
package scenario

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"sort"
	"strings"
	"time"

	"shenliyuan/internal/ai"
)

// ScenarioSpec 是一个可控 Provider 驱动的端到端场景。
type ScenarioSpec struct {
	ID            string
	Category      string
	Description   string
	Deterministic bool
	ExpectedMode  ai.ExecutionMode
	Run           func(context.Context) ScenarioResult
}

// ScenarioResult 记录真实执行链的行为指标，不保存用户原文、工具原文或个人事实。
type ScenarioResult struct {
	CaseID  string `json:"case_id"`
	Success bool   `json:"success"`

	ExpectedMode      ai.ExecutionMode `json:"expected_mode,omitempty"`
	ObservedMode      ai.ExecutionMode `json:"observed_mode,omitempty"`
	ModeUpgrades      int              `json:"mode_upgrades"`
	BudgetExhaustions int              `json:"budget_exhaustions"`

	ToolCalls          int `json:"tool_calls"`
	ExternalCalls      int `json:"external_calls"`
	PlanningRounds     int `json:"planning_rounds"`
	ReplanCount        int `json:"replan_count"`
	ClarificationCount int `json:"clarification_count"`

	PersonalScopes     []string `json:"personal_scopes,omitempty"`
	PermissionDenials  int      `json:"permission_denials"`
	PermissionBypasses int      `json:"permission_bypasses"`
	CrossUserLeakage   int      `json:"cross_user_leakage"`
	DiscardedResults   int      `json:"discarded_results"`
	Degraded           bool     `json:"degraded"`

	ActionProposals      int `json:"action_proposals"`
	ActionCommits        int `json:"action_commits"`
	VerifiedCommits      int `json:"verified_commits"`
	DuplicateSideEffects int `json:"duplicate_side_effects"`
	FalseSuccesses       int `json:"false_successes"`

	DurationMS int64 `json:"duration_ms"`

	FailureReason string `json:"failure_reason,omitempty"`
}

type ScenarioCaseResult struct {
	CaseID      string         `json:"case_id"`
	Category    string         `json:"category"`
	Description string         `json:"description"`
	Result      ScenarioResult `json:"result"`
}

// ScenarioSummary 是 scenario baseline 的聚合格式，与 deterministic baseline 分离。
type ScenarioSummary struct {
	Name        string  `json:"name"`
	Cases       int     `json:"cases"`
	Passed      int     `json:"passed"`
	SuccessRate float64 `json:"success_rate"`

	AverageToolCalls      float64                         `json:"average_tool_calls"`
	ToolCalls             int                             `json:"tool_calls"`
	ExternalCalls         int                             `json:"external_calls"`
	P95ToolCalls          int                             `json:"p95_tool_calls"`
	AveragePlanningRounds float64                         `json:"average_planning_rounds"`
	P95PlanningRounds     int                             `json:"p95_planning_rounds"`
	ReplanCount           int                             `json:"replan_count"`
	Clarifications        int                             `json:"clarifications"`
	PermissionDenials     int                             `json:"permission_denials"`
	PermissionBypasses    int                             `json:"permission_bypasses"`
	CrossUserLeakage      int                             `json:"cross_user_leakage"`
	PersonalScopeReads    int                             `json:"personal_scope_reads"`
	DegradedRuns          int                             `json:"degraded_runs"`
	LateResultsDropped    int                             `json:"late_results_dropped"`
	ActionProposals       int                             `json:"action_proposals"`
	ActionCommits         int                             `json:"action_commits"`
	VerifiedCommits       int                             `json:"verified_commits"`
	DuplicateSideEffects  int                             `json:"duplicate_side_effects"`
	FalseSuccesses        int                             `json:"false_successes"`
	AverageLatencyMS      float64                         `json:"average_latency_ms"`
	P95LatencyMS          int64                           `json:"p95_latency_ms"`
	ModeAccuracy          float64                         `json:"mode_accuracy"`
	ModeUpgrades          int                             `json:"mode_upgrades"`
	BudgetExhaustions     int                             `json:"budget_exhaustions"`
	ExecutionModes        map[string]ExecutionModeSummary `json:"execution_modes,omitempty"`

	Categories map[string]int       `json:"categories"`
	Failures   []ScenarioCaseResult `json:"failures,omitempty"`
	Results    []ScenarioCaseResult `json:"results,omitempty"`
}

// ExecutionModeSummary 输出各档位独立的效率基线，避免不同任务复杂度混成一个平均值。
type ExecutionModeSummary struct {
	Cases                 int     `json:"cases"`
	Passed                int     `json:"passed"`
	AverageToolCalls      float64 `json:"average_tool_calls"`
	P95ToolCalls          int     `json:"p95_tool_calls"`
	AveragePlanningRounds float64 `json:"average_planning_rounds"`
	P95PlanningRounds     int     `json:"p95_planning_rounds"`
	AverageLatencyMS      float64 `json:"average_latency_ms"`
	P95LatencyMS          int64   `json:"p95_latency_ms"`
	ModeUpgrades          int     `json:"mode_upgrades"`
	BudgetExhaustions     int     `json:"budget_exhaustions"`
}

// Baseline 保存人工确认过的 scenario 指标，不允许测试自动覆盖。
type Baseline struct {
	Version string `json:"version"`
	Cases   int    `json:"cases"`

	SuccessRate          float64 `json:"success_rate"`
	AverageToolCalls     float64 `json:"average_tool_calls"`
	MaxAverageToolGrowth float64 `json:"max_average_tool_growth"`
	MaxP95ToolCalls      int     `json:"max_p95_tool_calls"`
	MaxP95PlanningRounds int     `json:"max_p95_planning_rounds"`
	MinActionCommits     int     `json:"min_action_commits"`
	MinVerifiedCommits   int     `json:"min_verified_commits"`

	MaxDuplicateSideEffects int `json:"max_duplicate_side_effects"`
	MaxFalseSuccesses       int `json:"max_false_successes"`
	MaxPermissionBypasses   int `json:"max_permission_bypasses"`
}

type ThresholdViolation struct {
	Metric   string  `json:"metric"`
	Baseline float64 `json:"baseline"`
	Actual   float64 `json:"actual"`
	Reason   string  `json:"reason"`
}

func RunSuite(ctx context.Context, cases []ScenarioSpec) (ScenarioSummary, error) {
	if err := ValidateCatalog(cases); err != nil {
		return ScenarioSummary{}, err
	}
	summary := ScenarioSummary{
		Name: "Agent Regression Scenario Suite", Categories: make(map[string]int),
		ExecutionModes: make(map[string]ExecutionModeSummary), Results: make([]ScenarioCaseResult, 0, len(cases)),
	}
	modeResults := make(map[string][]ScenarioCaseResult)
	for _, testCase := range cases {
		started := time.Now()
		result := ScenarioResult{CaseID: testCase.ID}
		if testCase.Run == nil {
			result.FailureReason = "scenario_runner_missing"
		} else {
			result = testCase.Run(ctx)
			if result.CaseID == "" {
				result.CaseID = testCase.ID
			}
		}
		if result.DurationMS <= 0 {
			result.DurationMS = time.Since(started).Milliseconds()
			if result.DurationMS <= 0 {
				result.DurationMS = 1
			}
		}
		caseResult := ScenarioCaseResult{CaseID: testCase.ID, Category: testCase.Category, Description: testCase.Description, Result: result}
		summary.Results = append(summary.Results, caseResult)
		modeKey := string(result.ExpectedMode)
		if modeKey == "" {
			modeKey = string(result.ObservedMode)
		}
		if modeKey != "" {
			modeResults[modeKey] = append(modeResults[modeKey], caseResult)
		}
		summary.Cases++
		summary.Categories[testCase.Category]++
		if result.Success {
			summary.Passed++
		} else {
			summary.Failures = append(summary.Failures, caseResult)
		}
		summary.ToolCalls += result.ToolCalls
		summary.ExternalCalls += result.ExternalCalls
		summary.ReplanCount += result.ReplanCount
		summary.Clarifications += result.ClarificationCount
		summary.PermissionDenials += result.PermissionDenials
		summary.PermissionBypasses += result.PermissionBypasses
		summary.CrossUserLeakage += result.CrossUserLeakage
		summary.PersonalScopeReads += len(result.PersonalScopes)
		summary.LateResultsDropped += result.DiscardedResults
		summary.ActionProposals += result.ActionProposals
		summary.ActionCommits += result.ActionCommits
		summary.VerifiedCommits += result.VerifiedCommits
		summary.DuplicateSideEffects += result.DuplicateSideEffects
		summary.FalseSuccesses += result.FalseSuccesses
		summary.ModeUpgrades += result.ModeUpgrades
		summary.BudgetExhaustions += result.BudgetExhaustions
		summary.AverageLatencyMS += float64(result.DurationMS)
		if result.Degraded {
			summary.DegradedRuns++
		}
	}
	if summary.Cases > 0 {
		summary.SuccessRate = float64(summary.Passed) / float64(summary.Cases)
		summary.AverageToolCalls = float64(summary.ToolCalls) / float64(summary.Cases)
		summary.AveragePlanningRounds = averageInt(summary.Results, func(result ScenarioResult) int { return result.PlanningRounds })
		summary.AverageLatencyMS /= float64(summary.Cases)
		summary.P95ToolCalls = percentileInt(summary.Results, func(result ScenarioResult) int { return result.ToolCalls })
		summary.P95PlanningRounds = percentileInt(summary.Results, func(result ScenarioResult) int { return result.PlanningRounds })
		summary.P95LatencyMS = int64(percentileInt64(summary.Results, func(result ScenarioResult) int64 { return result.DurationMS }))
		modeMatched := 0
		modeCases := 0
		for _, caseResult := range summary.Results {
			if caseResult.Result.ExpectedMode == "" {
				continue
			}
			modeCases++
			if caseResult.Result.ExpectedMode == caseResult.Result.ObservedMode {
				modeMatched++
			}
		}
		if modeCases > 0 {
			summary.ModeAccuracy = float64(modeMatched) / float64(modeCases)
		}
	}
	for mode, results := range modeResults {
		stats := ExecutionModeSummary{Cases: len(results)}
		for _, caseResult := range results {
			result := caseResult.Result
			if result.Success {
				stats.Passed++
			}
			stats.AverageToolCalls += float64(result.ToolCalls)
			stats.AveragePlanningRounds += float64(result.PlanningRounds)
			stats.AverageLatencyMS += float64(result.DurationMS)
			stats.ModeUpgrades += result.ModeUpgrades
			stats.BudgetExhaustions += result.BudgetExhaustions
		}
		if stats.Cases > 0 {
			stats.AverageToolCalls /= float64(stats.Cases)
			stats.AveragePlanningRounds /= float64(stats.Cases)
			stats.AverageLatencyMS /= float64(stats.Cases)
			stats.P95ToolCalls = percentileInt(results, func(result ScenarioResult) int { return result.ToolCalls })
			stats.P95PlanningRounds = percentileInt(results, func(result ScenarioResult) int { return result.PlanningRounds })
			stats.P95LatencyMS = int64(percentileInt64(results, func(result ScenarioResult) int64 { return result.DurationMS }))
		}
		summary.ExecutionModes[mode] = stats
	}
	return summary, nil
}

func ValidateCatalog(cases []ScenarioSpec) error {
	if len(cases) < 20 {
		return fmt.Errorf("scenario suite requires at least 20 cases, got %d", len(cases))
	}
	seen := make(map[string]struct{}, len(cases))
	for _, testCase := range cases {
		if strings.TrimSpace(testCase.ID) == "" || strings.TrimSpace(testCase.Category) == "" || strings.TrimSpace(testCase.Description) == "" {
			return fmt.Errorf("scenario id, category and description are required")
		}
		if !testCase.Deterministic {
			return fmt.Errorf("scenario %q must be deterministic", testCase.ID)
		}
		if _, exists := seen[testCase.ID]; exists {
			return fmt.Errorf("duplicate scenario id %q", testCase.ID)
		}
		seen[testCase.ID] = struct{}{}
	}
	return nil
}

func LoadBaseline(reader io.Reader) (Baseline, error) {
	var baseline Baseline
	if reader == nil {
		return baseline, fmt.Errorf("scenario baseline reader is required")
	}
	if err := json.NewDecoder(reader).Decode(&baseline); err != nil {
		return baseline, err
	}
	if baseline.Version == "" || baseline.Cases < 20 {
		return baseline, fmt.Errorf("invalid scenario baseline")
	}
	return baseline, nil
}

func CompareBaseline(summary ScenarioSummary, baseline Baseline) []ThresholdViolation {
	violations := make([]ThresholdViolation, 0)
	if summary.SuccessRate < baseline.SuccessRate {
		violations = append(violations, threshold("success_rate", baseline.SuccessRate, summary.SuccessRate, "scenario success rate 不得低于基线"))
	}
	if baseline.AverageToolCalls > 0 && summary.AverageToolCalls > baseline.AverageToolCalls*(1+baseline.MaxAverageToolGrowth) {
		violations = append(violations, threshold("average_tool_calls", baseline.AverageToolCalls*(1+baseline.MaxAverageToolGrowth), summary.AverageToolCalls, "平均 Tool Calls 增长超过阈值"))
	}
	if summary.P95ToolCalls > baseline.MaxP95ToolCalls {
		violations = append(violations, threshold("p95_tool_calls", float64(baseline.MaxP95ToolCalls), float64(summary.P95ToolCalls), "P95 Tool Calls 超过阈值"))
	}
	if summary.P95PlanningRounds > baseline.MaxP95PlanningRounds {
		violations = append(violations, threshold("p95_planning_rounds", float64(baseline.MaxP95PlanningRounds), float64(summary.P95PlanningRounds), "P95 Planning Rounds 超过阈值"))
	}
	if summary.ActionCommits < baseline.MinActionCommits {
		violations = append(violations, threshold("action_commits", float64(baseline.MinActionCommits), float64(summary.ActionCommits), "Action commits 未达到场景覆盖要求"))
	}
	if summary.VerifiedCommits < baseline.MinVerifiedCommits {
		violations = append(violations, threshold("verified_commits", float64(baseline.MinVerifiedCommits), float64(summary.VerifiedCommits), "verified commits 未达到场景覆盖要求"))
	}
	if summary.DuplicateSideEffects > baseline.MaxDuplicateSideEffects {
		violations = append(violations, threshold("duplicate_side_effects", float64(baseline.MaxDuplicateSideEffects), float64(summary.DuplicateSideEffects), "重复副作用必须为 0"))
	}
	if summary.FalseSuccesses > baseline.MaxFalseSuccesses {
		violations = append(violations, threshold("false_successes", float64(baseline.MaxFalseSuccesses), float64(summary.FalseSuccesses), "false action success 必须为 0"))
	}
	if summary.PermissionBypasses > baseline.MaxPermissionBypasses {
		violations = append(violations, threshold("permission_bypasses", float64(baseline.MaxPermissionBypasses), float64(summary.PermissionBypasses), "permission bypass 必须为 0"))
	}
	if summary.CrossUserLeakage > 0 {
		violations = append(violations, threshold("cross_user_leakage", 0, float64(summary.CrossUserLeakage), "cross-user leakage 必须为 0"))
	}
	return violations
}

func FormatSummary(summary ScenarioSummary) string {
	lines := []string{
		"Agent Regression Scenario Suite",
		"",
		fmt.Sprintf("Cases                 %d", summary.Cases),
		fmt.Sprintf("Passed                %d", summary.Passed),
		fmt.Sprintf("Success Rate          %.1f%%", summary.SuccessRate*100),
		"",
		fmt.Sprintf("Avg Tool Calls        %.2f", summary.AverageToolCalls),
		fmt.Sprintf("P95 Tool Calls        %d", summary.P95ToolCalls),
		fmt.Sprintf("Avg Planning Rounds   %.2f", summary.AveragePlanningRounds),
		fmt.Sprintf("P95 Planning Rounds   %d", summary.P95PlanningRounds),
		fmt.Sprintf("Replan Count          %d", summary.ReplanCount),
		fmt.Sprintf("Clarifications        %d", summary.Clarifications),
		fmt.Sprintf("Permission Denials    %d", summary.PermissionDenials),
		fmt.Sprintf("Permission Bypasses   %d", summary.PermissionBypasses),
		fmt.Sprintf("Cross-user Leakage    %d", summary.CrossUserLeakage),
		fmt.Sprintf("Personal Scope Reads  %d", summary.PersonalScopeReads),
		fmt.Sprintf("Degraded Runs         %d", summary.DegradedRuns),
		fmt.Sprintf("Late Results Dropped  %d", summary.LateResultsDropped),
		fmt.Sprintf("Action Proposals      %d", summary.ActionProposals),
		fmt.Sprintf("Action Commits        %d", summary.ActionCommits),
		fmt.Sprintf("Verified Commits      %d", summary.VerifiedCommits),
		fmt.Sprintf("Duplicate Side Effects %d", summary.DuplicateSideEffects),
		fmt.Sprintf("False Successes       %d", summary.FalseSuccesses),
		fmt.Sprintf("Mode Accuracy         %.1f%%", summary.ModeAccuracy*100),
		fmt.Sprintf("Mode Upgrades         %d", summary.ModeUpgrades),
		fmt.Sprintf("Budget Exhaustions    %d", summary.BudgetExhaustions),
		fmt.Sprintf("Avg Latency           %.2fms", summary.AverageLatencyMS),
		fmt.Sprintf("P95 Latency           %dms", summary.P95LatencyMS),
		fmt.Sprintf("External Calls        %d", summary.ExternalCalls),
		"",
		"Category Coverage",
	}
	categories := make([]string, 0, len(summary.Categories))
	for category := range summary.Categories {
		categories = append(categories, category)
	}
	sort.Strings(categories)
	for _, category := range categories {
		lines = append(lines, fmt.Sprintf("%-22s %d", category, summary.Categories[category]))
	}
	lines = append(lines, "", "Execution Mode Baselines")
	for _, mode := range []string{string(ai.ExecutionFast), string(ai.ExecutionNormal), string(ai.ExecutionDeep)} {
		stats, ok := summary.ExecutionModes[mode]
		if !ok {
			continue
		}
		lines = append(lines,
			fmt.Sprintf("%-22s cases=%d avg_tools=%.2f p95_tools=%d avg_rounds=%.2f p95_rounds=%d avg_active_ms=%.2f upgrades=%d budget_exhaustions=%d",
				mode, stats.Cases, stats.AverageToolCalls, stats.P95ToolCalls, stats.AveragePlanningRounds,
				stats.P95PlanningRounds, stats.AverageLatencyMS, stats.ModeUpgrades, stats.BudgetExhaustions),
		)
	}
	return strings.Join(lines, "\n")
}

func averageInt(results []ScenarioCaseResult, value func(ScenarioResult) int) float64 {
	if len(results) == 0 {
		return 0
	}
	total := 0
	for _, result := range results {
		total += value(result.Result)
	}
	return float64(total) / float64(len(results))
}

func percentileInt(results []ScenarioCaseResult, value func(ScenarioResult) int) int {
	values := make([]int, 0, len(results))
	for _, result := range results {
		values = append(values, value(result.Result))
	}
	if len(values) == 0 {
		return 0
	}
	sort.Ints(values)
	index := int(math.Ceil(float64(len(values)) * 0.95))
	if index < 1 {
		index = 1
	}
	if index > len(values) {
		index = len(values)
	}
	return values[index-1]
}

func percentileInt64(results []ScenarioCaseResult, value func(ScenarioResult) int64) int64 {
	values := make([]int64, 0, len(results))
	for _, result := range results {
		values = append(values, value(result.Result))
	}
	if len(values) == 0 {
		return 0
	}
	sort.Slice(values, func(i, j int) bool { return values[i] < values[j] })
	index := int(math.Ceil(float64(len(values)) * 0.95))
	if index < 1 {
		index = 1
	}
	if index > len(values) {
		index = len(values)
	}
	return values[index-1]
}

func threshold(metric string, baseline, actual float64, reason string) ThresholdViolation {
	return ThresholdViolation{Metric: metric, Baseline: baseline, Actual: actual, Reason: reason}
}
