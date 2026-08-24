package ai

import (
	"encoding/json"
	"time"
)

// ExecutionMode 是同一个 Agent Kernel 使用的执行预算档位，而不是三套 Agent。
type ExecutionMode string

const (
	ExecutionFast   ExecutionMode = "fast"
	ExecutionNormal ExecutionMode = "normal"
	ExecutionDeep   ExecutionMode = "deep"
)

// ExecutionProfile 将任务结构映射为可审计的执行预算。
//
// 这里故意只消费已经解析完成的 GoalSpec，不直接建立第二套关键词 intent
// router。目标结构由 Goal/Capability 层形成，执行策略只负责预算决策。
type ExecutionProfile struct {
	Mode ExecutionMode `json:"mode"`

	EstimatedDomains     int  `json:"estimated_domains"`
	RequiresPersonalData bool `json:"requires_personal_data"`
	RequiresComparison   bool `json:"requires_comparison"`
	RequiresAction       bool `json:"requires_action"`
	AmbiguityLevel       int  `json:"ambiguity_level"`

	MaxToolCalls         int   `json:"max_tool_calls"`
	MaxPlanningRounds    int   `json:"max_planning_rounds"`
	MaxExternalCalls     int   `json:"max_external_calls"`
	TargetLatencyMS      int64 `json:"target_latency_ms"`
	MaxSameToolCalls     int   `json:"max_same_tool_calls"`
	MaxModelTokens       int   `json:"max_model_tokens"`
	MaxDurationMS        int64 `json:"max_duration_ms"`
	MaxConsecutiveNoGain int   `json:"max_consecutive_no_gain"`
}

// ExecutionProfileForGoal 根据任务结构计算执行档位。
//
// 结构信号来自 GoalSpec 的个人上下文、动作意图、派生子目标、约束和未知项。
// 不读取原始用户文本，也不根据单个关键词直接路由工具。
func ExecutionProfileForGoal(goal GoalSpec) ExecutionProfile {
	profile := ExecutionProfile{
		Mode:                 ExecutionFast,
		EstimatedDomains:     1,
		RequiresPersonalData: goal.RequiresPersonalContext,
		RequiresComparison:   goal.ActionIntent == "recommend",
		RequiresAction:       goal.ActionIntent == "plan" || goal.ActionIntent == "change",
		AmbiguityLevel:       len(goal.Unknowns),
		MaxSameToolCalls:     1,
		MaxConsecutiveNoGain: 2,
	}

	// 个人上下文、比较/推荐和副作用分别代表独立的执行约束域。
	// 约束文本本身不作为意图路由，只用于估算任务的组合复杂度。
	if profile.RequiresPersonalData {
		profile.EstimatedDomains++
	}
	if profile.RequiresAction {
		profile.EstimatedDomains++
	}
	if len(goal.HardConstraints)+len(goal.SoftConstraints) > 0 {
		profile.EstimatedDomains++
	}
	if len(goal.DerivedSubgoals) > 2 {
		profile.EstimatedDomains++
	}
	if profile.EstimatedDomains > 4 {
		profile.EstimatedDomains = 4
	}

	if profile.AmbiguityLevel > 3 {
		profile.AmbiguityLevel = 3
	}
	switch {
	case profile.RequiresAction && goal.ActionIntent == "plan":
		profile.Mode = ExecutionDeep
	case profile.EstimatedDomains >= 3 || profile.AmbiguityLevel >= 2:
		profile.Mode = ExecutionDeep
	case profile.RequiresPersonalData || profile.RequiresComparison || profile.RequiresAction || profile.AmbiguityLevel > 0:
		profile.Mode = ExecutionNormal
	}
	return applyExecutionBudget(profile)
}

// DefaultExecutionProfile 返回固定的策略预算，便于测试、灰度和离线基线复用。
func DefaultExecutionProfile(mode ExecutionMode) ExecutionProfile {
	if mode != ExecutionFast && mode != ExecutionNormal && mode != ExecutionDeep {
		mode = ExecutionFast
	}
	return applyExecutionBudget(ExecutionProfile{Mode: mode, EstimatedDomains: 1})
}

func applyExecutionBudget(profile ExecutionProfile) ExecutionProfile {
	switch profile.Mode {
	case ExecutionDeep:
		profile.MaxToolCalls = 12
		profile.MaxPlanningRounds = 6
		profile.MaxExternalCalls = 8
		profile.TargetLatencyMS = 12000
		profile.MaxSameToolCalls = 3
		profile.MaxModelTokens = 12000
		profile.MaxDurationMS = 90000
		profile.MaxConsecutiveNoGain = 2
	case ExecutionNormal:
		profile.MaxToolCalls = 5
		profile.MaxPlanningRounds = 3
		profile.MaxExternalCalls = 4
		profile.TargetLatencyMS = 5000
		profile.MaxSameToolCalls = 2
		profile.MaxModelTokens = 8192
		profile.MaxDurationMS = 60000
		profile.MaxConsecutiveNoGain = 2
	default:
		profile.Mode = ExecutionFast
		profile.MaxToolCalls = 2
		profile.MaxPlanningRounds = 1
		profile.MaxExternalCalls = 1
		profile.TargetLatencyMS = 2000
		profile.MaxSameToolCalls = 1
		profile.MaxModelTokens = 4096
		profile.MaxDurationMS = 30000
		profile.MaxConsecutiveNoGain = 2
	}
	return profile
}

func executionModeRank(mode ExecutionMode) int {
	switch mode {
	case ExecutionDeep:
		return 3
	case ExecutionNormal:
		return 2
	default:
		return 1
	}
}

// UpgradeExecutionProfile 只允许升级，不允许因运行中噪声自动降级。
func UpgradeExecutionProfile(current *ExecutionProfile, target ExecutionMode) bool {
	if current == nil || executionModeRank(target) <= executionModeRank(current.Mode) {
		return false
	}
	current.Mode = target
	*current = applyExecutionBudget(*current)
	return true
}

func budgetForExecutionProfile(profile ExecutionProfile) AgentBudget {
	class := BudgetSimple
	switch profile.Mode {
	case ExecutionNormal:
		class = BudgetNormal
	case ExecutionDeep:
		class = BudgetComplex
	}
	return AgentBudget{
		Class:                class,
		MaxToolCalls:         profile.MaxToolCalls,
		MaxSameToolCalls:     profile.MaxSameToolCalls,
		MaxPlanningRounds:    profile.MaxPlanningRounds,
		MaxDurationMs:        profile.MaxDurationMS,
		MaxModelTokens:       profile.MaxModelTokens,
		MaxExternalCalls:     profile.MaxExternalCalls,
		MaxConsecutiveNoGain: profile.MaxConsecutiveNoGain,
		MaxDuration:          durationFromMilliseconds(profile.MaxDurationMS),
	}
}

func durationFromMilliseconds(value int64) time.Duration {
	if value <= 0 {
		return 0
	}
	return time.Duration(value) * time.Millisecond
}

// BudgetForExecutionProfile 将策略预算转换为 Kernel 现有 BudgetTracker 的契约。
func BudgetForExecutionProfile(profile ExecutionProfile) AgentBudget {
	profile = applyExecutionBudget(profile)
	budget := budgetForExecutionProfile(profile)
	return budget
}

// ExecutionComplexityFromObservation 只读取工具返回的结构化观察，判断是否应升级预算。
// 工具结果中的 next_hints、候选数组和显式 domains 都是已脱敏的结构信号。
func ExecutionComplexityFromObservation(result ToolResultEnvelope) ExecutionMode {
	if len(result.NextHints) >= 2 {
		return ExecutionDeep
	}
	if len(result.NextHints) == 1 {
		return ExecutionNormal
	}
	if len(result.Data) == 0 || !json.Valid(result.Data) {
		return ExecutionFast
	}
	var object map[string]json.RawMessage
	if json.Unmarshal(result.Data, &object) != nil {
		return ExecutionFast
	}
	if raw, ok := object["domains"]; ok {
		var domains []json.RawMessage
		if json.Unmarshal(raw, &domains) == nil && len(domains) >= 3 {
			return ExecutionDeep
		}
	}
	for _, key := range []string{"items", "candidates", "alternatives"} {
		raw, ok := object[key]
		if !ok {
			continue
		}
		var values []json.RawMessage
		if json.Unmarshal(raw, &values) == nil && len(values) > 1 {
			return ExecutionNormal
		}
	}
	return ExecutionFast
}

// UpgradeExecutionFromObservation 应用观察带来的复杂度升级，并同步现有预算。
func UpgradeExecutionFromObservation(state *AgentRunState, result ToolResultEnvelope) (from, to ExecutionMode, upgraded bool) {
	if state == nil {
		return "", "", false
	}
	if state.ExecutionMode == "" {
		profile := ExecutionProfileForGoal(state.Goal)
		state.ExecutionMode, state.ExecutionProfile, state.Budget = profile.Mode, profile, BudgetForExecutionProfile(profile)
	}
	from = state.ExecutionMode
	target := ExecutionComplexityFromObservation(result)
	if target == ExecutionDeep && state.FeatureFlags != (FeatureFlagSnapshot{}) && !state.FeatureFlags.DeepModeEnabled {
		target = ExecutionNormal
	}
	if !UpgradeExecutionProfile(&state.ExecutionProfile, target) {
		return from, state.ExecutionMode, false
	}
	state.ExecutionMode = state.ExecutionProfile.Mode
	state.Budget = BudgetForExecutionProfile(state.ExecutionProfile)
	return from, state.ExecutionMode, true
}

func refreshExecutionProfile(state *AgentRunState) {
	if state == nil {
		return
	}
	proposed := ExecutionProfileForGoal(state.Goal)
	if state.FeatureFlags != (FeatureFlagSnapshot{}) && !state.FeatureFlags.DeepModeEnabled && proposed.Mode == ExecutionDeep {
		proposed.Mode = ExecutionNormal
		proposed = applyExecutionBudget(proposed)
	}
	if state.ExecutionMode == "" {
		state.ExecutionMode, state.ExecutionProfile = proposed.Mode, proposed
	} else {
		currentMode := state.ExecutionMode
		if state.FeatureFlags != (FeatureFlagSnapshot{}) && !state.FeatureFlags.DeepModeEnabled && currentMode == ExecutionDeep {
			currentMode = ExecutionNormal
		}
		if executionModeRank(proposed.Mode) > executionModeRank(currentMode) {
			currentMode = proposed.Mode
		}
		proposed.Mode = currentMode
		state.ExecutionMode, state.ExecutionProfile = currentMode, applyExecutionBudget(proposed)
	}
	state.Budget = BudgetForExecutionProfile(state.ExecutionProfile)
}
