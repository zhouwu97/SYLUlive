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
	if containsAnyContract(message, "我的", "我适合", "适合我", "我参加", "我当前", "本学期", "我的成绩", "我的课表") {
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
	ID         string          `json:"id"`
	Capability string          `json:"capability"`
	Arguments  json.RawMessage `json:"arguments"`
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
	RunID             string                `json:"run_id"`
	Goal              GoalSpec              `json:"goal"`
	KnownFacts        []string              `json:"known_facts,omitempty"`
	Observations      []AgentObservation    `json:"observations,omitempty"`
	CompletedSteps    []string              `json:"completed_steps,omitempty"`
	PendingActions    []AgentActionProposal `json:"pending_actions,omitempty"`
	Failures          []ToolError           `json:"failures,omitempty"`
	Budget            AgentBudget           `json:"budget"`
	ConstraintVersion int                   `json:"constraint_version"`
	PlanVersion       int                   `json:"plan_version"`
}

type AgentObservation struct {
	Capability string             `json:"capability"`
	Result     ToolResultEnvelope `json:"result"`
	CreatedAt  time.Time          `json:"created_at"`
}

type AgentActivityEvent struct {
	Type         string    `json:"type"`
	ActivityCode string    `json:"activity_code,omitempty"`
	Text         string    `json:"text,omitempty"`
	ToolName     string    `json:"tool_name,omitempty"`
	CreatedAt    time.Time `json:"created_at"`
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
