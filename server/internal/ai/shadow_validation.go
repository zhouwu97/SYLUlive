package ai

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
)

// AgentFeatureFlags 是 Agent v5 的运行时开关快照。
//
// 所有选择都在服务端完成，模型不能影响开关结果。名单是显式放行，
// 版本、能力和模式是附加过滤条件，百分比则使用稳定哈希避免同一用户
// 在请求之间漂移。Shadow 只记录决策，不执行工具，也不产生副作用。
type AgentFeatureFlags struct {
	Enabled             bool
	RolloutPercent      int
	RolloutUserIDs      []uint
	AppVersionAllowlist []string
	CapabilityAllowlist []string
	ModeAllowlist       []string

	ShadowEnabled       bool
	ShadowPercent       int
	ActionsEnabled      bool
	PersonalDataEnabled bool
	DeepModeEnabled     bool
}

type FeatureFlagInput struct {
	UserID     uint
	RunID      string
	AppVersion string
	Capability string
	Mode       ExecutionMode
}

// FeatureFlagSnapshot 写入 AgentStateJSON，保证运行中配置热变更不会改变本次 Run 的语义。
type FeatureFlagSnapshot struct {
	AgentEnabled        bool     `json:"agent_enabled"`
	RolloutMatched      bool     `json:"rollout_matched"`
	ShadowEnabled       bool     `json:"shadow_enabled"`
	ActionsEnabled      bool     `json:"actions_enabled"`
	PersonalDataEnabled bool     `json:"personal_data_enabled"`
	DeepModeEnabled     bool     `json:"deep_mode_enabled"`
	AppVersion          string   `json:"app_version,omitempty"`
	RolloutPercent      int      `json:"rollout_percent"`
	ShadowPercent       int      `json:"shadow_percent"`
	DecisionKey         string   `json:"decision_key,omitempty"`
	RolloutReasons      []string `json:"rollout_reasons,omitempty"`
}

func (snapshot FeatureFlagSnapshot) IsZero() bool {
	return !snapshot.AgentEnabled && !snapshot.RolloutMatched &&
		!snapshot.ShadowEnabled && !snapshot.ActionsEnabled &&
		!snapshot.PersonalDataEnabled && !snapshot.DeepModeEnabled &&
		snapshot.AppVersion == "" && snapshot.RolloutPercent == 0 &&
		snapshot.ShadowPercent == 0 && snapshot.DecisionKey == "" &&
		len(snapshot.RolloutReasons) == 0
}

func (f AgentFeatureFlags) Validate() error {
	if f.RolloutPercent < 0 || f.RolloutPercent > 100 {
		return errors.New("invalid agent rollout percentage")
	}
	if f.ShadowPercent < 0 || f.ShadowPercent > 100 {
		return errors.New("invalid agent shadow percentage")
	}
	for _, mode := range f.ModeAllowlist {
		if ExecutionMode(mode) != ExecutionFast && ExecutionMode(mode) != ExecutionNormal && ExecutionMode(mode) != ExecutionDeep {
			return fmt.Errorf("invalid agent mode allowlist value: %s", mode)
		}
	}
	return nil
}

func (f AgentFeatureFlags) isUserAllowed(userID uint) bool {
	if len(f.RolloutUserIDs) == 0 {
		return false
	}
	for _, allowed := range f.RolloutUserIDs {
		if allowed == userID {
			return true
		}
	}
	return false
}

func allowlistMatch(values []string, value string) bool {
	if len(values) == 0 {
		return true
	}
	value = strings.TrimSpace(value)
	for _, candidate := range values {
		if strings.TrimSpace(candidate) == value {
			return true
		}
	}
	return false
}

func modeAllowlistMatch(values []string, mode ExecutionMode) bool {
	if len(values) == 0 {
		return true
	}
	for _, candidate := range values {
		if strings.TrimSpace(candidate) == string(mode) {
			return true
		}
	}
	return false
}

func stablePercent(key string) int {
	digest := sha256.Sum256([]byte(key))
	return int((uint16(digest[0])<<8 | uint16(digest[1])) % 100)
}

func (f AgentFeatureFlags) decisionKey(input FeatureFlagInput, purpose string) string {
	identity := strings.TrimSpace(input.RunID)
	if input.UserID != 0 {
		// 用户 ID 优先保证 Agent 灰度稳定，避免同一用户在请求之间漂移。
		identity = fmt.Sprintf("user:%d", input.UserID)
	}
	if identity == "" {
		identity = "anonymous"
	}
	return strings.Join([]string{purpose, identity, strings.TrimSpace(input.AppVersion)}, "|")
}

func (f AgentFeatureFlags) matchesFilters(input FeatureFlagInput) bool {
	if !allowlistMatch(f.AppVersionAllowlist, input.AppVersion) || !modeAllowlistMatch(f.ModeAllowlist, input.Mode) {
		return false
	}
	// 能力白名单在具体工具调用时应用；创建 Run 时尚未有能力选择，
	// 空 Capability 不应让整个请求被误判为未灰度。
	return len(f.CapabilityAllowlist) == 0 || strings.TrimSpace(input.Capability) == "" || allowlistMatch(f.CapabilityAllowlist, input.Capability)
}

func (f AgentFeatureFlags) capabilityAllowed(capability string) bool {
	return allowlistMatch(f.CapabilityAllowlist, capability)
}

// AgentAllowed 判断该请求是否进入 Agent Kernel v5。
func (f AgentFeatureFlags) AgentAllowed(input FeatureFlagInput) bool {
	if !f.Enabled || !f.matchesFilters(input) {
		return false
	}
	if f.isUserAllowed(input.UserID) {
		return true
	}
	return stablePercent(f.decisionKey(input, "agent")) < f.RolloutPercent
}

// ShadowAllowed 判断是否为本次正式请求写入 Shadow 观察事件。
func (f AgentFeatureFlags) ShadowAllowed(input FeatureFlagInput) bool {
	if !f.ShadowEnabled || !f.matchesFilters(input) {
		return false
	}
	if f.isUserAllowed(input.UserID) {
		return true
	}
	key := input
	key.RunID = strings.TrimSpace(input.RunID)
	return stablePercent(f.decisionKey(key, "shadow")) < f.ShadowPercent
}

func (f AgentFeatureFlags) Snapshot(input FeatureFlagInput) FeatureFlagSnapshot {
	agentKey := f.decisionKey(input, "agent")
	agentAllowed := f.AgentAllowed(input)
	decisionDigest := sha256.Sum256([]byte(agentKey))
	return FeatureFlagSnapshot{
		AgentEnabled:        agentAllowed,
		RolloutMatched:      agentAllowed,
		ShadowEnabled:       f.ShadowAllowed(input),
		ActionsEnabled:      agentAllowed && f.ActionsEnabled,
		PersonalDataEnabled: agentAllowed && f.PersonalDataEnabled,
		DeepModeEnabled:     agentAllowed && f.DeepModeEnabled,
		AppVersion:          strings.TrimSpace(input.AppVersion),
		RolloutPercent:      f.RolloutPercent,
		ShadowPercent:       f.ShadowPercent,
		DecisionKey:         hex.EncodeToString(decisionDigest[:]),
		RolloutReasons:      f.rolloutReasons(input, agentAllowed),
	}
}

// rolloutReasons 只输出可审计的决策标签，不输出名单、能力配置或用户标识。
func (f AgentFeatureFlags) rolloutReasons(input FeatureFlagInput, matched bool) []string {
	reasons := make([]string, 0, 5)
	if !f.Enabled {
		return []string{"agent_disabled"}
	}
	if f.isUserAllowed(input.UserID) {
		reasons = append(reasons, "user_allowlist")
	}
	if len(f.AppVersionAllowlist) > 0 && allowlistMatch(f.AppVersionAllowlist, input.AppVersion) {
		reasons = append(reasons, "app_version_allowlist")
	}
	if len(f.ModeAllowlist) > 0 && modeAllowlistMatch(f.ModeAllowlist, input.Mode) {
		reasons = append(reasons, "mode_allowlist")
	}
	if !f.matchesFilters(input) {
		return append(reasons, "filter_miss")
	}
	if matched {
		reasons = append(reasons, "percentage_match")
	} else {
		reasons = append(reasons, "percentage_miss")
	}
	if !f.ActionsEnabled {
		reasons = append(reasons, "actions_kill_switch")
	}
	if !f.PersonalDataEnabled {
		reasons = append(reasons, "personal_data_kill_switch")
	}
	if !f.DeepModeEnabled {
		reasons = append(reasons, "deep_mode_kill_switch")
	}
	return reasons
}

// ShadowExecution 是不执行能力的观察记录。它没有 Executor 字段，避免把
// Shadow 误接到真实 ToolRegistry；任何 Action 只能进入 blocked 计数。
type ShadowExecution struct {
	TraceID         string
	Mode            ExecutionMode
	DecisionOnly    bool
	ActionProposals int
	BlockedActions  int
}

func NewShadowExecution(traceID string, mode ExecutionMode) ShadowExecution {
	return ShadowExecution{TraceID: strings.TrimSpace(traceID), Mode: mode, DecisionOnly: true}
}

func (s *ShadowExecution) ObserveActionProposal() {
	if s == nil || !s.DecisionOnly {
		return
	}
	s.ActionProposals++
	s.BlockedActions++
}

func (s ShadowExecution) Payload() map[string]interface{} {
	return map[string]interface{}{
		"trace_id":         s.TraceID,
		"execution_mode":   s.Mode,
		"shadow_only":      true,
		"action_proposals": s.ActionProposals,
		"blocked_actions":  s.BlockedActions,
		"side_effects":     0,
		"action_commits":   0,
		"decision_only":    s.DecisionOnly,
	}
}

type AgentFailureReason string

const (
	FailureModeWrong          AgentFailureReason = "mode_wrong"
	FailureCapabilityWrong    AgentFailureReason = "capability_wrong"
	FailureClarificationWrong AgentFailureReason = "clarification_wrong"
	FailureActionWrong        AgentFailureReason = "action_wrong"
	FailureAnswerWrong        AgentFailureReason = "answer_wrong"
	FailureLatencyTooHigh     AgentFailureReason = "latency_too_high"
	FailureCostTooHigh        AgentFailureReason = "cost_too_high"
	FailurePrivacyBoundary    AgentFailureReason = "privacy_boundary"
	FailureOther              AgentFailureReason = "other"
)

func (reason AgentFailureReason) Valid() bool {
	switch reason {
	case FailureModeWrong, FailureCapabilityWrong, FailureClarificationWrong,
		FailureActionWrong, FailureAnswerWrong, FailureLatencyTooHigh,
		FailureCostTooHigh, FailurePrivacyBoundary, FailureOther:
		return true
	default:
		return false
	}
}

func FailureReasonForCode(code string) AgentFailureReason {
	normalized := strings.ToLower(strings.TrimSpace(code))
	switch {
	case strings.Contains(normalized, "mode"):
		return FailureModeWrong
	case strings.Contains(normalized, "tool"), strings.Contains(normalized, "capability"), strings.HasPrefix(normalized, "mcp_"):
		return FailureCapabilityWrong
	case strings.Contains(normalized, "clarif"), strings.Contains(normalized, "consent"):
		return FailureClarificationWrong
	case strings.Contains(normalized, "action"):
		return FailureActionWrong
	case strings.Contains(normalized, "latency"), strings.Contains(normalized, "timeout"):
		return FailureLatencyTooHigh
	case strings.Contains(normalized, "budget"), strings.Contains(normalized, "cost"):
		return FailureCostTooHigh
	case strings.Contains(normalized, "privacy"), strings.Contains(normalized, "permission"):
		return FailurePrivacyBoundary
	default:
		return FailureOther
	}
}

type AgentUserSignal string

const (
	UserSignalCorrection               AgentUserSignal = "user.correction"
	UserSignalUnnecessaryClarification AgentUserSignal = "clarification.unnecessary"
	UserSignalAbandoned                AgentUserSignal = "run.abandoned"
	UserSignalRephrased                AgentUserSignal = "run.rephrased"
	UserSignalUsefulAnswer             AgentUserSignal = "answer.useful"
	UserSignalFirstActivity            AgentUserSignal = "run.first_activity"
	UserSignalFirstUsefulAnswer        AgentUserSignal = "answer.first_useful"
	UserSignalPossibleCorrection       AgentUserSignal = "possible_user_correction"
)

func (signal AgentUserSignal) Valid() bool {
	switch signal {
	case UserSignalCorrection, UserSignalUnnecessaryClarification,
		UserSignalAbandoned, UserSignalRephrased, UserSignalUsefulAnswer,
		UserSignalFirstActivity, UserSignalFirstUsefulAnswer,
		UserSignalPossibleCorrection:
		return true
	default:
		return false
	}
}

// RegressionScenarioCandidate 是 trace 转离线回归场景的稳定最小合同。
// 它只引用 trace 和失败分类，不复制问题正文、工具结果或个人数据。
type RegressionScenarioCandidate struct {
	CaseID        string             `json:"case_id"`
	SourceTraceID string             `json:"source_trace_id"`
	FailureReason AgentFailureReason `json:"failure_reason"`
	Candidate     bool               `json:"candidate"`
	Deterministic bool               `json:"deterministic"`
}

func (candidate RegressionScenarioCandidate) Payload() map[string]interface{} {
	return map[string]interface{}{
		"case_id":         candidate.CaseID,
		"source_trace_id": candidate.SourceTraceID,
		"failure_reason":  candidate.FailureReason,
		"candidate":       candidate.Candidate,
		"deterministic":   candidate.Deterministic,
	}
}

func isAgentActionTool(name string) bool {
	name = strings.TrimSpace(name)
	return name == "calendar.propose_action" || name == "calendar_propose_action" ||
		name == "draft_calendar_action" || name == "competition.propose_action" ||
		name == "competition_propose_action" || name == "competition.plan_add" ||
		name == "competition_plan_add"
}

func isAgentPersonalDataTool(name string) bool {
	name = strings.TrimSpace(name)
	return strings.HasPrefix(name, "academic.") || strings.HasPrefix(name, "academic_") ||
		strings.HasPrefix(name, "schedule.") || strings.HasPrefix(name, "schedule_") ||
		strings.HasPrefix(name, "personal_calendar.") || strings.HasPrefix(name, "personal_calendar_") ||
		strings.HasPrefix(name, "device.academic.") || strings.HasPrefix(name, "device_academic_") ||
		strings.HasPrefix(name, "device.schedule.") || strings.HasPrefix(name, "device_schedule_") ||
		name == "competition.get_my_plan" || name == "competition_get_my_plan" ||
		name == "competition.get_deadlines" || name == "competition_get_deadlines" ||
		name == "competition.get_calendar" || name == "competition_get_calendar"
}
