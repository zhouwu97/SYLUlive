// Package eval 提供 Agent Regression Suite 的稳定数据模型、Case 注册和汇总逻辑。
//
// 该包只负责观测与评估，不参与 Agent Kernel 的编排、规划或权限决策。
package eval

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"sort"
	"strings"
	"time"
)

// Category 是 deterministic regression 的稳定分类。
type Category string

const (
	CategoryCore        Category = "core"
	CategoryContext     Category = "context"
	CategoryPermission  Category = "permission"
	CategoryPlanning    Category = "planning"
	CategoryReplanning  Category = "replanning"
	CategoryAction      Category = "action"
	CategoryRecovery    Category = "recovery"
	CategoryDegradation Category = "degradation"
	CategorySecurity    Category = "security"
	CategoryCost        Category = "cost"
)

var requiredCategories = []Category{
	CategoryCore, CategoryContext, CategoryPermission, CategoryPlanning, CategoryReplanning,
	CategoryAction, CategoryRecovery, CategoryDegradation, CategorySecurity, CategoryCost,
}

// AgentEvalResult 是单个 Case 的统一结果。除 Success 外，所有字段都用于长期比较，
// 不应写入用户问题、工具原文、个人事实或模型思维链。
type AgentEvalResult struct {
	CaseID  string `json:"case_id"`
	Success bool   `json:"success"`

	ToolCalls          int `json:"tool_calls"`
	ExternalCalls      int `json:"external_calls"`
	PlanningRounds     int `json:"planning_rounds"`
	ReplanCount        int `json:"replan_count"`
	ClarificationCount int `json:"clarification_count"`

	PersonalScopes    []string `json:"personal_scopes,omitempty"`
	PermissionDenials int      `json:"permission_denials"`
	DiscardedResults  int      `json:"discarded_results"`
	Degraded          bool     `json:"degraded"`

	ActionCount          int `json:"action_count"`
	ActionVerifyFailures int `json:"action_verify_failures"`

	DurationMS int64 `json:"duration_ms"`

	ModelCalls   int   `json:"model_calls"`
	InputTokens  int64 `json:"input_tokens,omitempty"`
	OutputTokens int64 `json:"output_tokens,omitempty"`

	// 安全阈值字段用于阻断高风险回归，即使 case 的业务断言未失败也不能放行。
	PermissionBypasses        int `json:"permission_bypasses"`
	CrossUserLeakage          int `json:"cross_user_leakage"`
	ConfirmationBypasses      int `json:"confirmation_bypasses"`
	FalseActionSuccesses      int `json:"false_action_successes"`
	UnnecessaryPersonalAccess int `json:"unnecessary_personal_access"`

	FailureReason string `json:"failure_reason,omitempty"`
}

// CaseSpec 是一个可执行的 deterministic regression case。
type CaseSpec struct {
	ID            string
	Category      Category
	Description   string
	Deterministic bool
	Run           func(context.Context) AgentEvalResult
}

// ModelBehaviorCase 与 deterministic case 分离。它允许未来对同一 Case 重复运行，
// 使用统计阈值判断模型行为，而不会把 LLM 随机性带入稳定 CI。
type ModelBehaviorCase struct {
	ID             string
	Description    string
	Repetitions    int
	MinSuccessRate float64
	Run            func(context.Context) AgentEvalResult
}

type ModelBehaviorResult struct {
	CaseID      string  `json:"case_id"`
	Repetitions int     `json:"repetitions"`
	Passed      int     `json:"passed"`
	SuccessRate float64 `json:"success_rate"`
	PassedGate  bool    `json:"passed_gate"`
}

// CaseResult 保留 Case 元数据和执行结果，方便输出失败原因与分类覆盖。
type CaseResult struct {
	CaseID      string          `json:"case_id"`
	Category    Category        `json:"category"`
	Description string          `json:"description"`
	Result      AgentEvalResult `json:"result"`
}

// SuiteSummary 是一次 Suite 的机器可读摘要。
type SuiteSummary struct {
	Name        string  `json:"name"`
	Cases       int     `json:"cases"`
	Passed      int     `json:"passed"`
	SuccessRate float64 `json:"success_rate"`

	AverageToolCalls      float64 `json:"average_tool_calls"`
	P95ToolCalls          int     `json:"p95_tool_calls"`
	AveragePlanningRounds float64 `json:"average_planning_rounds"`
	ReplanCount           int     `json:"replan_count"`
	Clarifications        int     `json:"clarifications"`
	PermissionDenials     int     `json:"permission_denials"`
	PersonalScopeReads    int     `json:"personal_scope_reads"`
	DegradedRuns          int     `json:"degraded_runs"`
	LateResultsDropped    int     `json:"late_results_dropped"`
	ActionCommits         int     `json:"action_commits"`
	ActionCount           int     `json:"action_count"`
	ActionVerifyFailures  int     `json:"action_verify_failures"`
	AverageLatencyMS      float64 `json:"average_latency_ms"`
	P95LatencyMS          int64   `json:"p95_latency_ms"`

	ModelCalls    int   `json:"model_calls"`
	InputTokens   int64 `json:"input_tokens"`
	OutputTokens  int64 `json:"output_tokens"`
	ToolCalls     int   `json:"tool_calls"`
	ExternalCalls int   `json:"external_calls"`
	WallTimeMS    int64 `json:"wall_time_ms"`

	PermissionBypasses        int `json:"permission_bypasses"`
	CrossUserLeakage          int `json:"cross_user_leakage"`
	ConfirmationBypasses      int `json:"confirmation_bypasses"`
	FalseActionSuccesses      int `json:"false_action_successes"`
	UnnecessaryPersonalAccess int `json:"unnecessary_personal_access"`

	Categories map[Category]int `json:"categories"`
	Failures   []CaseResult     `json:"failures,omitempty"`
	Results    []CaseResult     `json:"results,omitempty"`
}

// Baseline 保存经过人工确认的基线。测试不会自动覆盖该文件。
type Baseline struct {
	Version string `json:"version"`
	Cases   int    `json:"cases"`

	SuccessRate          float64 `json:"success_rate"`
	AverageToolCalls     float64 `json:"average_tool_calls"`
	P95ToolCalls         int     `json:"p95_tool_calls"`
	MaxP95ToolCalls      int     `json:"max_p95_tool_calls"`
	MaxAverageToolGrowth float64 `json:"max_average_tool_growth"`

	PermissionBypasses        int `json:"permission_bypasses"`
	CrossUserLeakage          int `json:"cross_user_leakage"`
	ConfirmationBypasses      int `json:"confirmation_bypasses"`
	FalseActionSuccesses      int `json:"false_action_successes"`
	UnnecessaryPersonalAccess int `json:"unnecessary_personal_access"`
}

type ThresholdViolation struct {
	Metric   string  `json:"metric"`
	Baseline float64 `json:"baseline"`
	Actual   float64 `json:"actual"`
	Reason   string  `json:"reason"`
}

// RunDeterministicSuite 执行所有 deterministic case，并拒绝重复 ID、缺失分类或非确定性 case。
func RunDeterministicSuite(ctx context.Context, cases []CaseSpec) (SuiteSummary, error) {
	if err := ValidateCatalog(cases); err != nil {
		return SuiteSummary{}, err
	}
	started := time.Now()
	summary := SuiteSummary{Name: "Agent Regression Suite", Categories: make(map[Category]int), Results: make([]CaseResult, 0, len(cases))}
	for _, testCase := range cases {
		caseStarted := time.Now()
		result := AgentEvalResult{CaseID: testCase.ID}
		if testCase.Run == nil {
			result.FailureReason = "case_runner_missing"
		} else {
			result = testCase.Run(ctx)
			if result.CaseID == "" {
				result.CaseID = testCase.ID
			}
		}
		if result.DurationMS <= 0 {
			result.DurationMS = time.Since(caseStarted).Milliseconds()
		}
		caseResult := CaseResult{CaseID: testCase.ID, Category: testCase.Category, Description: testCase.Description, Result: result}
		summary.Results = append(summary.Results, caseResult)
		summary.Cases++
		summary.Categories[testCase.Category]++
		if result.Success {
			summary.Passed++
		} else {
			summary.Failures = append(summary.Failures, caseResult)
		}
		summary.ToolCalls += result.ToolCalls
		summary.ExternalCalls += result.ExternalCalls
		summary.ModelCalls += result.ModelCalls
		summary.InputTokens += result.InputTokens
		summary.OutputTokens += result.OutputTokens
		summary.ReplanCount += result.ReplanCount
		summary.Clarifications += result.ClarificationCount
		summary.PermissionDenials += result.PermissionDenials
		summary.PersonalScopeReads += len(result.PersonalScopes)
		if result.Degraded {
			summary.DegradedRuns++
		}
		summary.LateResultsDropped += result.DiscardedResults
		summary.ActionCount += result.ActionCount
		summary.ActionVerifyFailures += result.ActionVerifyFailures
		summary.WallTimeMS += result.DurationMS
		summary.PermissionBypasses += result.PermissionBypasses
		summary.CrossUserLeakage += result.CrossUserLeakage
		summary.ConfirmationBypasses += result.ConfirmationBypasses
		summary.FalseActionSuccesses += result.FalseActionSuccesses
		summary.UnnecessaryPersonalAccess += result.UnnecessaryPersonalAccess
	}
	if summary.Cases > 0 {
		summary.SuccessRate = float64(summary.Passed) / float64(summary.Cases)
		summary.AverageToolCalls = float64(summary.ToolCalls) / float64(summary.Cases)
		summary.AveragePlanningRounds = averagePlanningRounds(summary.Results)
		summary.AverageLatencyMS = float64(summary.WallTimeMS) / float64(summary.Cases)
		summary.P95ToolCalls = percentileInt(resultToolCalls(summary.Results), 95)
		summary.P95LatencyMS = int64(percentileInt64(resultLatencies(summary.Results), 95))
	}
	if summary.WallTimeMS <= 0 {
		summary.WallTimeMS = time.Since(started).Milliseconds()
	}
	return summary, nil
}

// RunModelBehaviorSuite 只提供统计执行框架；第一版不注册在线模型 Case。
func RunModelBehaviorSuite(ctx context.Context, cases []ModelBehaviorCase) ([]ModelBehaviorResult, error) {
	results := make([]ModelBehaviorResult, 0, len(cases))
	for _, testCase := range cases {
		if strings.TrimSpace(testCase.ID) == "" || testCase.Run == nil || testCase.Repetitions <= 0 || testCase.MinSuccessRate < 0 || testCase.MinSuccessRate > 1 {
			return nil, fmt.Errorf("invalid model behavior case %q", testCase.ID)
		}
		result := ModelBehaviorResult{CaseID: testCase.ID, Repetitions: testCase.Repetitions}
		for index := 0; index < testCase.Repetitions; index++ {
			if testCase.Run(ctx).Success {
				result.Passed++
			}
		}
		result.SuccessRate = float64(result.Passed) / float64(result.Repetitions)
		result.PassedGate = result.SuccessRate >= testCase.MinSuccessRate
		results = append(results, result)
	}
	return results, nil
}

func ValidateCatalog(cases []CaseSpec) error {
	if len(cases) < 60 {
		return fmt.Errorf("deterministic regression suite requires at least 60 cases, got %d", len(cases))
	}
	seen := make(map[string]struct{}, len(cases))
	categories := make(map[Category]bool, len(requiredCategories))
	for _, testCase := range cases {
		if strings.TrimSpace(testCase.ID) == "" || testCase.Category == "" || strings.TrimSpace(testCase.Description) == "" {
			return errorsf("case id, category and description are required")
		}
		if !testCase.Deterministic {
			return fmt.Errorf("case %q must be deterministic", testCase.ID)
		}
		if _, exists := seen[testCase.ID]; exists {
			return fmt.Errorf("duplicate case id %q", testCase.ID)
		}
		seen[testCase.ID] = struct{}{}
		categories[testCase.Category] = true
	}
	for _, category := range requiredCategories {
		if !categories[category] {
			return fmt.Errorf("missing required category %q", category)
		}
	}
	return nil
}

func errorsf(message string) error { return fmt.Errorf("%s", message) }

func CompareBaseline(summary SuiteSummary, baseline Baseline) []ThresholdViolation {
	violations := make([]ThresholdViolation, 0)
	if summary.PermissionBypasses > baseline.PermissionBypasses {
		violations = append(violations, violation("permission_bypasses", float64(baseline.PermissionBypasses), float64(summary.PermissionBypasses), "permission bypass 必须为 0"))
	}
	if summary.CrossUserLeakage > baseline.CrossUserLeakage {
		violations = append(violations, violation("cross_user_leakage", float64(baseline.CrossUserLeakage), float64(summary.CrossUserLeakage), "cross-user leakage 必须为 0"))
	}
	if summary.ConfirmationBypasses > baseline.ConfirmationBypasses {
		violations = append(violations, violation("confirmation_bypasses", float64(baseline.ConfirmationBypasses), float64(summary.ConfirmationBypasses), "confirmation bypass 必须为 0"))
	}
	if summary.FalseActionSuccesses > baseline.FalseActionSuccesses {
		violations = append(violations, violation("false_action_successes", float64(baseline.FalseActionSuccesses), float64(summary.FalseActionSuccesses), "false action success 必须为 0"))
	}
	if summary.UnnecessaryPersonalAccess > baseline.UnnecessaryPersonalAccess {
		violations = append(violations, violation("unnecessary_personal_access", float64(baseline.UnnecessaryPersonalAccess), float64(summary.UnnecessaryPersonalAccess), "不必要的个人数据访问必须为 0"))
	}
	if summary.SuccessRate < baseline.SuccessRate {
		violations = append(violations, violation("success_rate", baseline.SuccessRate, summary.SuccessRate, "deterministic success rate 不得低于基线"))
	}
	if summary.P95ToolCalls > baseline.MaxP95ToolCalls {
		violations = append(violations, violation("p95_tool_calls", float64(baseline.MaxP95ToolCalls), float64(summary.P95ToolCalls), "P95 Tool Calls 超过允许上限"))
	}
	maxAverage := baseline.AverageToolCalls * (1 + baseline.MaxAverageToolGrowth)
	if baseline.AverageToolCalls > 0 && summary.AverageToolCalls > maxAverage {
		violations = append(violations, violation("average_tool_calls", maxAverage, summary.AverageToolCalls, "平均 Tool Calls 增长超过阈值"))
	}
	return violations
}

func LoadBaseline(reader io.Reader) (Baseline, error) {
	var baseline Baseline
	if reader == nil {
		return baseline, errorsf("baseline reader is required")
	}
	if err := json.NewDecoder(reader).Decode(&baseline); err != nil {
		return baseline, err
	}
	if baseline.Version == "" || baseline.Cases < 60 {
		return baseline, errorsf("invalid regression baseline")
	}
	if baseline.MaxP95ToolCalls <= 0 {
		baseline.MaxP95ToolCalls = baseline.P95ToolCalls
	}
	return baseline, nil
}

func FormatSummary(summary SuiteSummary) string {
	lines := []string{
		"Agent Regression Suite",
		"",
		fmt.Sprintf("Cases                 %d", summary.Cases),
		fmt.Sprintf("Passed                %d", summary.Passed),
		fmt.Sprintf("Success Rate          %.1f%%", summary.SuccessRate*100),
		"",
		fmt.Sprintf("Avg Tool Calls        %.2f", summary.AverageToolCalls),
		fmt.Sprintf("P95 Tool Calls        %d", summary.P95ToolCalls),
		fmt.Sprintf("Avg Planning Rounds   %.2f", summary.AveragePlanningRounds),
		fmt.Sprintf("Replan Count           %d", summary.ReplanCount),
		fmt.Sprintf("Clarifications        %d", summary.Clarifications),
		fmt.Sprintf("Permission Denials    %d", summary.PermissionDenials),
		fmt.Sprintf("Personal Scope Reads  %d", summary.PersonalScopeReads),
		fmt.Sprintf("Degraded Runs         %d", summary.DegradedRuns),
		fmt.Sprintf("Late Results Dropped  %d", summary.LateResultsDropped),
		fmt.Sprintf("Action Count           %d", summary.ActionCount),
		fmt.Sprintf("Action Commits         %d", summary.ActionCommits),
		fmt.Sprintf("Verify Failures       %d", summary.ActionVerifyFailures),
		fmt.Sprintf("Avg Latency           %.2fms", summary.AverageLatencyMS),
		fmt.Sprintf("P95 Latency           %dms", summary.P95LatencyMS),
		"",
		fmt.Sprintf("Model Calls           %d", summary.ModelCalls),
		fmt.Sprintf("Input Tokens          %d", summary.InputTokens),
		fmt.Sprintf("Output Tokens         %d", summary.OutputTokens),
		fmt.Sprintf("External Calls        %d", summary.ExternalCalls),
		"",
		"Category Coverage",
	}
	for _, category := range requiredCategories {
		lines = append(lines, fmt.Sprintf("%-22s %d", string(category), summary.Categories[category]))
	}
	return strings.Join(lines, "\n")
}

func violation(metric string, baseline, actual float64, reason string) ThresholdViolation {
	return ThresholdViolation{Metric: metric, Baseline: baseline, Actual: actual, Reason: reason}
}

func averagePlanningRounds(results []CaseResult) float64 {
	if len(results) == 0 {
		return 0
	}
	var total int
	for _, result := range results {
		total += result.Result.PlanningRounds
	}
	return float64(total) / float64(len(results))
}

func resultToolCalls(results []CaseResult) []int {
	values := make([]int, 0, len(results))
	for _, result := range results {
		values = append(values, result.Result.ToolCalls)
	}
	return values
}

func resultLatencies(results []CaseResult) []int64 {
	values := make([]int64, 0, len(results))
	for _, result := range results {
		values = append(values, result.Result.DurationMS)
	}
	return values
}

func percentileInt(values []int, percentile int) int {
	if len(values) == 0 {
		return 0
	}
	sort.Ints(values)
	index := int(math.Ceil(float64(len(values)) * float64(percentile) / 100))
	if index < 1 {
		index = 1
	}
	if index > len(values) {
		index = len(values)
	}
	return values[index-1]
}

func percentileInt64(values []int64, percentile int) int64 {
	if len(values) == 0 {
		return 0
	}
	sort.Slice(values, func(i, j int) bool { return values[i] < values[j] })
	index := int(math.Ceil(float64(len(values)) * float64(percentile) / 100))
	if index < 1 {
		index = 1
	}
	if index > len(values) {
		index = len(values)
	}
	return values[index-1]
}
