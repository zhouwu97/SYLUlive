package ai

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

// AgentContractVersion 是 Agent Control Plane 与纯能力层之间的语义契约版本。
// Provider、MCP transport 和数据库实现都不应改变这个版本内的字段含义。
const AgentContractVersion = "5"

type SideEffectLevel string

const (
	SideEffectNone     SideEffectLevel = "none"
	SideEffectProposal SideEffectLevel = "proposal"
	SideEffectWrite    SideEffectLevel = "write"
	SideEffectExternal SideEffectLevel = "external"
)

type ConfirmationPolicy string

const (
	ConfirmationNever  ConfirmationPolicy = "never"
	ConfirmationIfRisk ConfirmationPolicy = "if_risk"
	ConfirmationAlways ConfirmationPolicy = "always"
)

type FreshnessClass string

const (
	FreshnessStatic FreshnessClass = "static"
	FreshnessDaily  FreshnessClass = "daily"
	FreshnessLive   FreshnessClass = "live"
	FreshnessRun    FreshnessClass = "run"
)

// GoalConstraint 保留约束的来源和强度，避免把用户明确说的话和模型推断混在一起。
type GoalConstraint struct {
	Text   string `json:"text"`
	Source string `json:"source"` // explicit / system / inferred
	Hard   bool   `json:"hard"`
}

type GoalSpec struct {
	Objective               string           `json:"objective"`
	HardConstraints         []GoalConstraint `json:"hard_constraints,omitempty"`
	SoftConstraints         []GoalConstraint `json:"soft_constraints,omitempty"`
	DerivedSubgoals         []string         `json:"derived_subgoals,omitempty"`
	Unknowns                []string         `json:"unknowns,omitempty"`
	RequiresPersonalContext bool             `json:"requires_personal_context"`
	ActionIntent            string           `json:"action_intent"` // answer / recommend / plan / change
}

// ParseGoalSpec 只负责形成可审计的初始目标，不替模型决定完整工具计划。
// 关键词只用于提取约束和预算等级，真正的下一步由 Planner 决定。
func ParseGoalSpec(message string, pageContext *AgentContextEnvelope) GoalSpec {
	message = strings.TrimSpace(message)
	goal := GoalSpec{Objective: message, ActionIntent: "answer"}
	if message == "" {
		goal.Unknowns = []string{"objective"}
		return goal
	}
	if containsAnyContract(message, "推荐", "适合", "值得", "找几个", "比较") {
		goal.ActionIntent = "recommend"
	}
	if containsAnyContract(message, "安排", "规划", "计划", "排进日历", "加入日程") {
		goal.ActionIntent = "plan"
	}
	if containsAnyContract(message, "添加", "加入", "删除", "修改", "设置提醒") {
		goal.ActionIntent = "change"
	}
	if containsAnyContract(message, "不要撞课", "不影响上课", "不要影响上课", "别撞课", "不能冲突", "不冲突") {
		goal.HardConstraints = append(goal.HardConstraints, GoalConstraint{Text: "不得与课程安排冲突", Source: "explicit", Hard: true})
		goal.RequiresPersonalContext = true
	}
	if containsAnyContract(message, "不要太忙", "别太忙", "时间压力不要太大", "空闲") {
		goal.SoftConstraints = append(goal.SoftConstraints, GoalConstraint{Text: "控制时间压力", Source: "explicit"})
	}
	if containsAnyContract(message, "周六不要", "周日不要", "这周不行", "不要安排") {
		goal.HardConstraints = append(goal.HardConstraints, GoalConstraint{Text: "避开用户明确排除的时间", Source: "explicit", Hard: true})
		goal.RequiresPersonalContext = true
	}
	if containsAnyContract(message, "我的", "我适合", "适合我", "我参加", "我当前", "我", "本学期", "我的成绩", "我的课表") {
		goal.RequiresPersonalContext = true
	}
	if goal.ActionIntent == "recommend" {
		goal.DerivedSubgoals = append(goal.DerivedSubgoals, "核对候选事实与截止时间")
	}
	if goal.RequiresPersonalContext {
		goal.DerivedSubgoals = append(goal.DerivedSubgoals, "只在必要且获授权时读取个人上下文")
	}
	if len(goal.HardConstraints) > 0 {
		goal.DerivedSubgoals = append(goal.DerivedSubgoals, "验证候选方案是否满足硬约束")
	}
	if pageContext != nil && len(pageContext.ContextRefs) > 0 {
		// 页面引用是最小实体上下文，不自动升级为个人数据授权。
		for _, ref := range pageContext.ContextRefs {
			if ref.Type == "competition_event" || ref.Type == "academic_term" {
				goal.Objective = message + "（基于当前页面实体）"
			}
		}
	}
	return goal
}

func containsAnyContract(value string, candidates ...string) bool {
	for _, candidate := range candidates {
		if strings.Contains(value, candidate) {
			return true
		}
	}
	return false
}

type ContextLayer string

const (
	ContextIdentity ContextLayer = "identity"
	ContextProfile  ContextLayer = "stable_profile"
	ContextLive     ContextLayer = "live_state"
	ContextEpisodic ContextLayer = "episodic"
)

type ContextRequest struct {
	Layers []ContextLayer `json:"layers"`
	Scopes []string       `json:"scopes,omitempty"`
}

type ContextValue struct {
	Layer     ContextLayer    `json:"layer"`
	Key       string          `json:"key"`
	Value     json.RawMessage `json:"value"`
	AsOf      time.Time       `json:"as_of"`
	Freshness FreshnessClass  `json:"freshness"`
	Source    string          `json:"source,omitempty"`
}

type ContextResolver func(context.Context, ContextRequest) ([]ContextValue, error)

// ContextBroker 只调度按需上下文。Identity 层可以被服务端内部使用，但永不出现在 Resolve 的模型视图中。
type ContextBroker struct {
	resolvers map[ContextLayer]ContextResolver
}

func NewContextBroker() *ContextBroker {
	return &ContextBroker{resolvers: make(map[ContextLayer]ContextResolver)}
}

func (b *ContextBroker) Register(layer ContextLayer, resolver ContextResolver) error {
	if b == nil || resolver == nil || layer == "" {
		return errors.New("invalid_context_resolver")
	}
	b.resolvers[layer] = resolver
	return nil
}

func (b *ContextBroker) Resolve(ctx context.Context, request ContextRequest) ([]ContextValue, error) {
	if b == nil {
		return nil, errors.New("context_broker_unavailable")
	}
	result := make([]ContextValue, 0)
	seen := make(map[string]struct{})
	for _, layer := range request.Layers {
		if layer == ContextIdentity {
			continue
		}
		resolver := b.resolvers[layer]
		if resolver == nil {
			continue
		}
		values, err := resolver(ctx, request)
		if err != nil {
			return nil, fmt.Errorf("resolve %s: %w", layer, err)
		}
		for _, value := range values {
			if value.Layer == ContextIdentity || value.Key == "" {
				continue
			}
			key := string(value.Layer) + "\x00" + value.Key
			if _, exists := seen[key]; exists {
				continue
			}
			seen[key] = struct{}{}
			result = append(result, value)
		}
	}
	sort.SliceStable(result, func(i, j int) bool {
		if result[i].Layer != result[j].Layer {
			return result[i].Layer < result[j].Layer
		}
		return result[i].Key < result[j].Key
	})
	return result, nil
}

type ToolError struct {
	Code      string `json:"code"`
	Message   string `json:"message,omitempty"`
	Retryable bool   `json:"retryable"`
}

// ToolResultEnvelope 是 MCP 和本地工具统一的观察输入。
// Data 保持 JSON 原文，避免先反序列化为 map 后丢失数值或时间精度。
type ToolResultEnvelope struct {
	OK         bool            `json:"ok"`
	Data       json.RawMessage `json:"data,omitempty"`
	AsOf       time.Time       `json:"as_of,omitempty"`
	Freshness  FreshnessClass  `json:"freshness,omitempty"`
	SourceRefs []string        `json:"source_refs,omitempty"`
	Warnings   []string        `json:"warnings,omitempty"`
	NextHints  []string        `json:"next_hints,omitempty"`
	Error      *ToolError      `json:"error,omitempty"`
}

func DecodeToolResult(raw json.RawMessage) (ToolResultEnvelope, error) {
	if len(bytes.TrimSpace(raw)) == 0 || !json.Valid(raw) {
		return ToolResultEnvelope{}, errors.New("tool_result_invalid")
	}
	var envelope ToolResultEnvelope
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return ToolResultEnvelope{}, err
	}
	if envelope.OK || envelope.Error != nil || len(envelope.Data) > 0 {
		return envelope, nil
	}
	// 兼容旧工具：旧工具结果不代表失败，只是没有统一 envelope 元数据。
	envelope.OK = true
	envelope.Data = append(json.RawMessage(nil), raw...)
	envelope.Freshness = FreshnessLive
	return envelope, nil
}

type BudgetClass string

const (
	BudgetSimple  BudgetClass = "simple"
	BudgetNormal  BudgetClass = "normal"
	BudgetComplex BudgetClass = "complex"
)

type AgentBudget struct {
	Class                BudgetClass   `json:"class"`
	MaxToolCalls         int           `json:"max_tool_calls"`
	MaxSameToolCalls     int           `json:"max_same_tool_calls"`
	MaxPlanningRounds    int           `json:"max_planning_rounds"`
	MaxDurationMs        int64         `json:"max_duration_ms"`
	MaxModelTokens       int           `json:"max_model_tokens"`
	MaxExternalCalls     int           `json:"max_external_calls"`
	MaxConsecutiveNoGain int           `json:"max_consecutive_no_gain"`
	MaxDuration          time.Duration `json:"-"`
}

func BudgetForGoal(goal GoalSpec) AgentBudget {
	if goal.ActionIntent == "plan" || len(goal.HardConstraints)+len(goal.SoftConstraints) >= 3 {
		return AgentBudget{
			Class: BudgetComplex, MaxToolCalls: 12, MaxSameToolCalls: 3, MaxPlanningRounds: 8,
			MaxDurationMs: 90000, MaxModelTokens: 12000, MaxExternalCalls: 3, MaxConsecutiveNoGain: 2,
			MaxDuration: 90 * time.Second,
		}
	}
	if goal.RequiresPersonalContext || goal.ActionIntent == "recommend" || len(goal.Unknowns) > 0 {
		return AgentBudget{
			Class: BudgetNormal, MaxToolCalls: 7, MaxSameToolCalls: 2, MaxPlanningRounds: 5,
			MaxDurationMs: 60000, MaxModelTokens: 8192, MaxExternalCalls: 2, MaxConsecutiveNoGain: 2,
			MaxDuration: 60 * time.Second,
		}
	}
	return AgentBudget{
		Class: BudgetSimple, MaxToolCalls: 3, MaxSameToolCalls: 1, MaxPlanningRounds: 3,
		MaxDurationMs: 30000, MaxModelTokens: 4096, MaxExternalCalls: 1, MaxConsecutiveNoGain: 2,
		MaxDuration: 30 * time.Second,
	}
}

type ToolCallFingerprint struct {
	ToolName string
	Hash     string
}

func NewToolCallFingerprint(toolName string, arguments json.RawMessage) ToolCallFingerprint {
	hash := sha256.Sum256(arguments)
	return ToolCallFingerprint{ToolName: toolName, Hash: hex.EncodeToString(hash[:])}
}

type BudgetTracker struct {
	Budget                 AgentBudget
	Calls                  int
	Seen                   map[ToolCallFingerprint]int
	ToolCallsByName        map[string]int
	PlanningRounds         int
	ExternalCalls          int
	Observations           int
	LastObservationHash    string
	ConsecutiveNoGainCount int
}

func NewBudgetTracker(budget AgentBudget) *BudgetTracker {
	return &BudgetTracker{
		Budget:          budget,
		Seen:            make(map[ToolCallFingerprint]int),
		ToolCallsByName: make(map[string]int),
	}
}

func (t *BudgetTracker) Admit(toolName string, arguments json.RawMessage, retryable bool) error {
	if t == nil || t.Budget.MaxToolCalls <= 0 {
		return errors.New("agent_budget_unavailable")
	}
	if t.Calls >= t.Budget.MaxToolCalls {
		return errors.New("agent_tool_budget_exhausted")
	}
	if t.Budget.MaxSameToolCalls > 0 && t.ToolCallsByName[toolName] >= t.Budget.MaxSameToolCalls {
		return errors.New("agent_same_tool_budget_exhausted")
	}
	fingerprint := NewToolCallFingerprint(toolName, arguments)
	if t.Seen[fingerprint] > 0 && !retryable {
		return errors.New("agent_duplicate_tool_call")
	}
	t.Seen[fingerprint]++
	t.ToolCallsByName[toolName]++
	t.Calls++
	return nil
}

func (t *BudgetTracker) BeginPlanningRound() error {
	if t == nil || t.Budget.MaxPlanningRounds <= 0 {
		return errors.New("agent_planning_budget_unavailable")
	}
	if t.PlanningRounds >= t.Budget.MaxPlanningRounds {
		return errors.New("agent_planning_budget_exhausted")
	}
	t.PlanningRounds++
	return nil
}

func (t *BudgetTracker) AdmitExternalCall() error {
	if t == nil || t.Budget.MaxExternalCalls <= 0 {
		return errors.New("agent_external_budget_unavailable")
	}
	if t.ExternalCalls >= t.Budget.MaxExternalCalls {
		return errors.New("agent_external_budget_exhausted")
	}
	t.ExternalCalls++
	return nil
}

func (t *BudgetTracker) Observe() {
	if t != nil {
		t.Observations++
	}
}

// ObserveResult 用语义结果而不是工具名称判断信息增益，防止通过改变参数重复返回同一事实。
func (t *BudgetTracker) ObserveResult(result ToolResultEnvelope) error {
	if t == nil {
		return errors.New("agent_budget_unavailable")
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return errors.New("agent_observation_invalid")
	}
	hash := sha256.Sum256(encoded)
	observationHash := hex.EncodeToString(hash[:])
	if observationHash == t.LastObservationHash {
		t.ConsecutiveNoGainCount++
	} else {
		t.ConsecutiveNoGainCount = 0
	}
	t.LastObservationHash = observationHash
	t.Observations++
	if t.Budget.MaxConsecutiveNoGain > 0 && t.ConsecutiveNoGainCount >= t.Budget.MaxConsecutiveNoGain {
		return errors.New("agent_information_stalled")
	}
	return nil
}

type AgentDecisionType string

const (
	DecisionToolCall      AgentDecisionType = "tool_call"
	DecisionRequestUser   AgentDecisionType = "request_user"
	DecisionProposeAction AgentDecisionType = "propose_action"
	DecisionRespond       AgentDecisionType = "respond"
)

type AgentToolCall struct {
	ID                string          `json:"id"`
	Capability        string          `json:"capability"`
	Arguments         json.RawMessage `json:"arguments"`
	PlanningRound     int             `json:"planning_round,omitempty"`
	ConstraintVersion int             `json:"constraint_version,omitempty"`
}

type AgentActionProposal struct {
	Action               string          `json:"action"`
	Preview              string          `json:"preview"`
	Arguments            json.RawMessage `json:"arguments"`
	ExpectedEffect       string          `json:"expected_effect"`
	IdempotencyKey       string          `json:"idempotency_key"`
	RequiresConfirmation bool            `json:"requires_confirmation"`
	ExpiresAt            time.Time       `json:"expires_at"`
}

type AgentDecision struct {
	Type         AgentDecisionType    `json:"type"`
	ToolCall     *AgentToolCall       `json:"tool_call,omitempty"`
	UserQuestion string               `json:"user_question,omitempty"`
	ActionDraft  *AgentActionProposal `json:"action_draft,omitempty"`
	FinalAnswer  string               `json:"final_answer,omitempty"`
	GoalUpdate   *GoalSpec            `json:"goal_update,omitempty"`
}

type AgentRunState struct {
	RunID                   string                `json:"run_id"`
	Goal                    GoalSpec              `json:"goal"`
	FeatureFlags            FeatureFlagSnapshot   `json:"feature_flags,omitempty"`
	ExecutionMode           ExecutionMode         `json:"execution_mode,omitempty"`
	ExecutionProfile        ExecutionProfile      `json:"execution_profile,omitempty"`
	KnownFacts              []string              `json:"known_facts,omitempty"`
	Observations            []AgentObservation    `json:"observations,omitempty"`
	CompletedSteps          []string              `json:"completed_steps,omitempty"`
	PendingActions          []AgentActionProposal `json:"pending_actions,omitempty"`
	Failures                []ToolError           `json:"failures,omitempty"`
	PlanningRounds          int                   `json:"planning_rounds"`
	ToolCalls               int                   `json:"tool_calls"`
	UnavailableCapabilities []string              `json:"unavailable_capabilities,omitempty"`
	Budget                  AgentBudget           `json:"budget"`
	ConstraintVersion       int                   `json:"constraint_version"`
	PlanVersion             int                   `json:"plan_version"`
	Cost                    AgentCostMetrics      `json:"cost"`
}

type AgentObservation struct {
	Capability        string             `json:"capability"`
	Result            ToolResultEnvelope `json:"result"`
	PlanningRound     int                `json:"planning_round,omitempty"`
	ConstraintVersion int                `json:"constraint_version,omitempty"`
	PlanVersion       int                `json:"plan_version,omitempty"`
	CreatedAt         time.Time          `json:"created_at"`
}

// AgentTraceFields 是审计事件中的运行元数据，不包含 CoT、提示词或工具原始结果。
type AgentTraceFields struct {
	RunID             string        `json:"run_id,omitempty"`
	PlanningRound     int           `json:"planning_round,omitempty"`
	ConstraintVersion int           `json:"constraint_version,omitempty"`
	PlanVersion       int           `json:"plan_version,omitempty"`
	DurationMs        int64         `json:"duration_ms,omitempty"`
	NewFactCount      int           `json:"new_fact_count,omitempty"`
	ExecutionMode     ExecutionMode `json:"execution_mode,omitempty"`
}

// AgentCostMetrics 是 Runtime 和 Regression Suite 共用的脱敏计量格式。
// TokenUsageAvailable=false 时，零值只表示 Provider 没有提供 usage，不能解释为免费。
type AgentCostMetrics struct {
	ModelCalls          int   `json:"model_calls"`
	InputTokens         int64 `json:"input_tokens"`
	OutputTokens        int64 `json:"output_tokens"`
	ToolCalls           int   `json:"tool_calls"`
	ExternalCalls       int   `json:"external_calls"`
	PlanningRounds      int   `json:"planning_rounds"`
	ReplanCount         int   `json:"replan_count"`
	WallTimeMS          int64 `json:"wall_time_ms"`
	ActiveComputeTimeMS int64 `json:"active_compute_time_ms"`
	UserWaitTimeMS      int64 `json:"user_wait_time_ms"`
	TokenUsageAvailable bool  `json:"token_usage_available"`
}

// AgentTraceMetrics 是从脱敏 Trace 派生的可长期比较指标，不包含问题正文、
// 工具原文或个人事实。它既可用于单 Run 汇总，也可交给离线 Eval 聚合。
type AgentTraceMetrics struct {
	ToolCalls                  int            `json:"tool_calls"`
	ReplanCount                int            `json:"replan_count"`
	DiscardedLateResults       int            `json:"discarded_late_results"`
	PermissionDenials          int            `json:"permission_denials"`
	PersonalScopesAccessed     int            `json:"personal_scopes_accessed"`
	ClarificationCount         int            `json:"clarification_count"`
	TotalLatencyMs             int64          `json:"total_latency_ms"`
	DegradedRuns               int            `json:"degraded_runs"`
	ActionVerificationFailures int            `json:"action_verification_failures"`
	ExecutionMode              ExecutionMode  `json:"execution_mode,omitempty"`
	ModeUpgrades               int            `json:"mode_upgrades"`
	FastEscalations            int            `json:"fast_escalations"`
	NormalEscalations          int            `json:"normal_escalations"`
	BudgetExhaustions          int            `json:"budget_exhaustions"`
	UserCorrections            int            `json:"user_corrections"`
	UnnecessaryClarifications  int            `json:"unnecessary_clarifications"`
	Abandonments               int            `json:"abandonments"`
	Rephrases                  int            `json:"rephrases"`
	UsefulAnswers              int            `json:"useful_answers"`
	FirstUsefulAnswers         int            `json:"first_useful_answers"`
	PossibleUserCorrections    int            `json:"possible_user_corrections"`
	TimeToFirstActivityMs      int64          `json:"time_to_first_activity_ms"`
	TimeToUsefulAnswerMs       int64          `json:"time_to_useful_answer_ms"`
	FailureTaxonomy            map[string]int `json:"failure_taxonomy,omitempty"`
	ModelCalls                 int            `json:"model_calls"`
	InputTokens                int64          `json:"input_tokens"`
	OutputTokens               int64          `json:"output_tokens"`
	ExternalCalls              int            `json:"external_calls"`
	PlanningRounds             int            `json:"planning_rounds"`
	ActiveComputeTimeMs        int64          `json:"active_compute_time_ms"`
	UserWaitTimeMs             int64          `json:"user_wait_time_ms"`
	TokenUsageAvailable        bool           `json:"token_usage_available"`
	RunSucceeded               bool           `json:"run_succeeded"`
	RunFailed                  bool           `json:"run_failed"`
	ToolLatencyMs              []int64        `json:"-"`
}

// Observe 从一个已脱敏的 Agent 事件中提取长期指标。
func (metrics *AgentTraceMetrics) Observe(eventType string, payload []byte) {
	if metrics == nil {
		return
	}
	var event struct {
		DurationMs            int64              `json:"duration_ms"`
		ErrorCode             string             `json:"error_code"`
		CapabilityStatus      string             `json:"capability_status"`
		PostconditionVerified *bool              `json:"postcondition_verified"`
		ExecutionMode         ExecutionMode      `json:"execution_mode"`
		FromMode              ExecutionMode      `json:"from_mode"`
		ToMode                ExecutionMode      `json:"to_mode"`
		BudgetExhausted       bool               `json:"budget_exhausted"`
		ModelCalls            int                `json:"model_calls"`
		InputTokens           int64              `json:"input_tokens"`
		OutputTokens          int64              `json:"output_tokens"`
		ExternalCalls         int                `json:"external_calls"`
		PlanningRounds        int                `json:"planning_rounds"`
		ActiveComputeTimeMs   int64              `json:"active_compute_time_ms"`
		UserWaitTimeMs        int64              `json:"user_wait_time_ms"`
		TimeToUsefulAnswerMs  int64              `json:"time_to_useful_answer_ms"`
		TimeToFirstActivityMs int64              `json:"time_to_first_activity_ms"`
		TokenUsageAvailable   *bool              `json:"token_usage_available"`
		FailureReason         AgentFailureReason `json:"failure_reason"`
	}
	_ = json.Unmarshal(payload, &event)
	if event.ExecutionMode != "" {
		metrics.ExecutionMode = event.ExecutionMode
	}
	metrics.ModelCalls += event.ModelCalls
	metrics.InputTokens += event.InputTokens
	metrics.OutputTokens += event.OutputTokens
	metrics.ExternalCalls += event.ExternalCalls
	metrics.PlanningRounds += event.PlanningRounds
	metrics.ActiveComputeTimeMs += event.ActiveComputeTimeMs
	metrics.UserWaitTimeMs += event.UserWaitTimeMs
	if event.TokenUsageAvailable != nil {
		metrics.TokenUsageAvailable = metrics.TokenUsageAvailable || *event.TokenUsageAvailable
	}
	if event.BudgetExhausted {
		metrics.BudgetExhaustions++
	}
	switch eventType {
	case "tool.requested":
		metrics.ToolCalls++
	case "tool.completed":
		if event.DurationMs > 0 {
			metrics.TotalLatencyMs += event.DurationMs
			metrics.ToolLatencyMs = append(metrics.ToolLatencyMs, event.DurationMs)
		}
		if event.ErrorCode == "permission_denied" {
			metrics.PermissionDenials++
		}
		if event.CapabilityStatus == "unavailable" || strings.HasPrefix(event.ErrorCode, "mcp_") {
			if metrics.DegradedRuns == 0 {
				metrics.DegradedRuns = 1
			}
		}
	case "plan.revised":
		metrics.ReplanCount++
	case "execution_mode.upgraded":
		metrics.ModeUpgrades++
		if event.FromMode == ExecutionFast && event.ToMode == ExecutionNormal {
			metrics.FastEscalations++
		}
		if event.FromMode == ExecutionNormal && event.ToMode == ExecutionDeep {
			metrics.NormalEscalations++
		}
	case "tool.discarded":
		metrics.DiscardedLateResults++
	case "personal_data.evidence":
		metrics.PersonalScopesAccessed++
	case "consent.required", "clarification.required":
		metrics.ClarificationCount++
	case "action.verification_failed":
		metrics.ActionVerificationFailures++
	case "user.correction":
		metrics.UserCorrections++
	case "possible_user_correction":
		metrics.PossibleUserCorrections++
	case "clarification.unnecessary":
		metrics.UnnecessaryClarifications++
	case "run.abandoned":
		metrics.Abandonments++
	case "run.rephrased":
		metrics.Rephrases++
	case "run.first_activity":
		if event.TimeToFirstActivityMs > 0 {
			metrics.TimeToFirstActivityMs = event.TimeToFirstActivityMs
		}
	case "answer.first_useful":
		metrics.FirstUsefulAnswers++
		if event.TimeToUsefulAnswerMs > 0 {
			metrics.TimeToUsefulAnswerMs = event.TimeToUsefulAnswerMs
		}
	case "answer.useful":
		metrics.UsefulAnswers++
		if event.TimeToUsefulAnswerMs > 0 {
			metrics.TimeToUsefulAnswerMs = event.TimeToUsefulAnswerMs
		}
	case "run.failure_classified":
		if event.FailureReason.Valid() {
			if metrics.FailureTaxonomy == nil {
				metrics.FailureTaxonomy = make(map[string]int)
			}
			metrics.FailureTaxonomy[string(event.FailureReason)]++
		}
	case "run.failed":
		if event.FailureReason.Valid() {
			if metrics.FailureTaxonomy == nil {
				metrics.FailureTaxonomy = make(map[string]int)
			}
			metrics.FailureTaxonomy[string(event.FailureReason)]++
		}
	case "run.completed":
		metrics.RunSucceeded = true
	case "run.cancelled", "run.expired":
		metrics.RunFailed = true
	}
}

// AgentEvalTrend 是跨提交/模型版本的稳定聚合格式。
type AgentEvalTrend struct {
	RunCount                     int            `json:"run_count"`
	SuccessRate                  float64        `json:"success_rate"`
	AverageToolCalls             float64        `json:"average_tool_calls"`
	P95ToolCalls                 int            `json:"p95_tool_calls"`
	ReplanRate                   float64        `json:"replan_rate"`
	DiscardedLateResults         int            `json:"discarded_late_results"`
	PermissionDenials            int            `json:"permission_denials"`
	PersonalScopesAccessed       int            `json:"personal_scopes_accessed"`
	ClarificationCount           int            `json:"clarification_count"`
	AverageRunLatencyMs          float64        `json:"average_run_latency_ms"`
	DegradedRuns                 int            `json:"degraded_runs"`
	ActionVerificationFailures   int            `json:"action_verification_failures"`
	UserCorrections              int            `json:"user_corrections"`
	UnnecessaryClarifications    int            `json:"unnecessary_clarifications"`
	Abandonments                 int            `json:"abandonments"`
	Rephrases                    int            `json:"rephrases"`
	UsefulAnswers                int            `json:"useful_answers"`
	PossibleUserCorrections      int            `json:"possible_user_corrections"`
	AverageTimeToFirstActivityMs float64        `json:"average_time_to_first_activity_ms"`
	AverageTimeToUsefulAnswerMs  float64        `json:"average_time_to_useful_answer_ms"`
	FailureTaxonomy              map[string]int `json:"failure_taxonomy,omitempty"`
}

func BuildAgentEvalTrend(samples []AgentTraceMetrics) AgentEvalTrend {
	trend := AgentEvalTrend{RunCount: len(samples)}
	if len(samples) == 0 {
		return trend
	}
	toolCalls := make([]int, 0, len(samples))
	completed, replanned := 0, 0
	var toolCallTotal, latencyTotal int64
	var usefulLatencyTotal int64
	usefulLatencyCount := 0
	var firstActivityTotal int64
	firstActivityCount := 0
	trend.FailureTaxonomy = make(map[string]int)
	for _, sample := range samples {
		if sample.RunSucceeded && !sample.RunFailed {
			completed++
		}
		if sample.ReplanCount > 0 {
			replanned++
		}
		toolCalls = append(toolCalls, sample.ToolCalls)
		toolCallTotal += int64(sample.ToolCalls)
		latencyTotal += sample.TotalLatencyMs
		trend.DiscardedLateResults += sample.DiscardedLateResults
		trend.PermissionDenials += sample.PermissionDenials
		trend.PersonalScopesAccessed += sample.PersonalScopesAccessed
		trend.ClarificationCount += sample.ClarificationCount
		trend.DegradedRuns += sample.DegradedRuns
		trend.ActionVerificationFailures += sample.ActionVerificationFailures
		trend.UserCorrections += sample.UserCorrections
		trend.PossibleUserCorrections += sample.PossibleUserCorrections
		trend.UnnecessaryClarifications += sample.UnnecessaryClarifications
		trend.Abandonments += sample.Abandonments
		trend.Rephrases += sample.Rephrases
		trend.UsefulAnswers += sample.UsefulAnswers
		if sample.TimeToUsefulAnswerMs > 0 {
			usefulLatencyTotal += sample.TimeToUsefulAnswerMs
			usefulLatencyCount++
		}
		if sample.TimeToFirstActivityMs > 0 {
			firstActivityTotal += sample.TimeToFirstActivityMs
			firstActivityCount++
		}
		for reason, count := range sample.FailureTaxonomy {
			trend.FailureTaxonomy[reason] += count
		}
	}
	trend.SuccessRate = float64(completed) / float64(len(samples))
	trend.AverageToolCalls = float64(toolCallTotal) / float64(len(samples))
	trend.P95ToolCalls = percentile95Ints(toolCalls)
	trend.ReplanRate = float64(replanned) / float64(len(samples))
	trend.AverageRunLatencyMs = float64(latencyTotal) / float64(len(samples))
	if usefulLatencyCount > 0 {
		trend.AverageTimeToUsefulAnswerMs = float64(usefulLatencyTotal) / float64(usefulLatencyCount)
	}
	if firstActivityCount > 0 {
		trend.AverageTimeToFirstActivityMs = float64(firstActivityTotal) / float64(firstActivityCount)
	}
	return trend
}

func percentile95Ints(values []int) int {
	if len(values) == 0 {
		return 0
	}
	sorted := append([]int(nil), values...)
	sort.Ints(sorted)
	index := (len(sorted)*95 + 99) / 100
	if index < 1 {
		index = 1
	}
	return sorted[index-1]
}

type AgentActivityEvent struct {
	Type              string            `json:"type"`
	ActivityCode      string            `json:"activity_code,omitempty"`
	Text              string            `json:"text,omitempty"`
	ToolName          string            `json:"tool_name,omitempty"`
	RunID             string            `json:"run_id,omitempty"`
	PlanningRound     int               `json:"planning_round,omitempty"`
	ConstraintVersion int               `json:"constraint_version,omitempty"`
	PlanVersion       int               `json:"plan_version,omitempty"`
	DurationMs        int64             `json:"duration_ms,omitempty"`
	NewFactCount      int               `json:"new_fact_count,omitempty"`
	ExecutionMode     ExecutionMode     `json:"execution_mode,omitempty"`
	FromMode          ExecutionMode     `json:"from_mode,omitempty"`
	ToMode            ExecutionMode     `json:"to_mode,omitempty"`
	Budget            *ExecutionProfile `json:"budget,omitempty"`
	CreatedAt         time.Time         `json:"created_at"`
}

func ValidateAgentDecision(decision AgentDecision, allowed map[string]AgentCapability) error {
	switch decision.Type {
	case DecisionToolCall:
		if decision.ToolCall == nil || decision.ToolCall.Capability == "" || len(decision.ToolCall.Arguments) == 0 || !json.Valid(decision.ToolCall.Arguments) {
			return errors.New("invalid_tool_decision")
		}
		if _, ok := allowed[decision.ToolCall.Capability]; !ok {
			return errors.New("capability_not_allowed")
		}
		if containsForbiddenToolIdentity(decision.ToolCall.Arguments) {
			return errors.New("tool_identity_parameter_forbidden")
		}
	case DecisionRequestUser:
		if strings.TrimSpace(decision.UserQuestion) == "" {
			return errors.New("invalid_user_question")
		}
	case DecisionProposeAction:
		if decision.ActionDraft == nil || strings.TrimSpace(decision.ActionDraft.Action) == "" || !decision.ActionDraft.RequiresConfirmation {
			return errors.New("action_confirmation_required")
		}
		capability, ok := allowed[decision.ActionDraft.Action]
		if !ok {
			return errors.New("capability_not_allowed")
		}
		if capability.Kind != "action" && capability.SideEffect == SideEffectNone {
			return errors.New("action_capability_invalid")
		}
		if !capability.RequiresConfirmation && capability.Confirmation != ConfirmationAlways && capability.Confirmation != ConfirmationIfRisk {
			return errors.New("action_confirmation_required")
		}
	case DecisionRespond:
		if strings.TrimSpace(decision.FinalAnswer) == "" {
			return errors.New("empty_agent_response")
		}
	default:
		return errors.New("unknown_agent_decision")
	}
	return nil
}
