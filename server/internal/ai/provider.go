package ai

import (
	"context"
	"errors"
)

// Message 是与具体模型厂商无关的对话消息。
type Message struct {
	Role       string            `json:"role"`
	Content    string            `json:"content"`
	ToolCalls  []ToolCallMessage `json:"tool_calls,omitempty"`
	ToolCallID string            `json:"tool_call_id,omitempty"`
}

// ToolCallMessage 保留厂商兼容的工具调用回合，避免把工具结果伪装成用户输入。
type ToolCallMessage struct {
	ID       string           `json:"id"`
	Type     string           `json:"type"`
	Function ToolCallFunction `json:"function"`
}

type ToolCallFunction struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

// ChatRequest 描述一次受 Context 控制的模型生成请求。
type ChatRequest struct {
	Messages    []Message
	Temperature float64
	MaxTokens   int
}

// ChatResponse 保留业务需要的最小响应与计量信息。
type ChatResponse struct {
	Content        string
	InputTokens    int
	OutputTokens   int
	CacheHitTokens int
}

type ProviderCapabilities struct {
	Streaming         bool
	ToolCalls         bool
	JSONSchema        bool
	ReasoningContent  bool
	PromptCache       bool
	UsageInStream     bool
	ForcedToolChoice  bool
	ParallelToolCalls bool
}

type ToolDefinition struct {
	Name        string                 `json:"name"`
	Description string                 `json:"description"`
	Parameters  map[string]interface{} `json:"parameters"`
}

type ProviderRequest struct {
	Messages    []Message
	Temperature float64
	MaxTokens   int
	Tools       []ToolDefinition
	// RequiredTool 由 Runtime 的依赖规划设置；非空时 Provider 必须先调用该工具。
	// Runtime 仍会独立校验实际调用，不能只依赖厂商实现 tool_choice。
	RequiredTool string
}

type ProviderEvent struct {
	Type           string
	Text           string
	CallID         string
	ToolName       string
	ArgumentsDelta string
	InputTokens    int
	OutputTokens   int
	CacheHitTokens int
	UsageAvailable bool
	FinishReason   string
}

const (
	ProviderEventTextDelta          = "text_delta"
	ProviderEventToolCallStarted    = "tool_call_started"
	ProviderEventToolArgumentsDelta = "tool_arguments_delta"
	ProviderEventToolCallCompleted  = "tool_call_completed"
	ProviderEventUsage              = "usage"
	ProviderEventCompleted          = "provider_completed"
)

type ProviderStream interface {
	Next(context.Context) (ProviderEvent, error)
	Close() error
}

// AIProvider 是正式运行时使用的流式 Provider 契约。
type AIProvider interface {
	Name() string
	Capabilities() ProviderCapabilities
	Start(context.Context, ProviderRequest) (ProviderStream, error)
}

type ProviderError struct {
	Class string
	Err   error
}

func (e *ProviderError) Error() string { return e.Class }
func (e *ProviderError) Unwrap() error { return e.Err }

const (
	ProviderErrorAuthentication  = "authentication_error"
	ProviderErrorRateLimited     = "rate_limited"
	ProviderErrorTimeout         = "provider_timeout"
	ProviderErrorUnavailable     = "provider_unavailable"
	ProviderErrorInvalid         = "invalid_response"
	ProviderErrorCancelled       = "context_cancelled"
	ProviderErrorRejected        = "content_rejected"
	ProviderErrorRequestRejected = "provider_request_rejected"
	ProviderErrorOutputLimit     = "output_limit_reached"
	ProviderErrorUnknown         = "unknown_provider_error"
)

// Provider 隔离外部模型厂商，生产实现与测试 Mock 必须遵守相同取消语义。
type Provider interface {
	Chat(context.Context, ChatRequest) (ChatResponse, error)
}

// MockProvider 供 P0 契约测试使用，不进行任何网络调用。
type MockProvider struct {
	Response ChatResponse
	Err      error
	Requests []ChatRequest
}

func (m *MockProvider) Name() string { return "mock" }

func (m *MockProvider) Capabilities() ProviderCapabilities {
	return ProviderCapabilities{Streaming: true, ToolCalls: true, JSONSchema: true, UsageInStream: true}
}

func (m *MockProvider) Start(ctx context.Context, request ProviderRequest) (ProviderStream, error) {
	response, err := m.Chat(ctx, ChatRequest{
		Messages: request.Messages, Temperature: request.Temperature, MaxTokens: request.MaxTokens,
	})
	if err != nil {
		return nil, err
	}
	events := []ProviderEvent{}
	if response.Content != "" {
		events = append(events, ProviderEvent{Type: ProviderEventTextDelta, Text: response.Content})
	}
	events = append(events,
		ProviderEvent{Type: ProviderEventUsage, InputTokens: response.InputTokens, OutputTokens: response.OutputTokens, CacheHitTokens: response.CacheHitTokens,
			UsageAvailable: response.InputTokens > 0 || response.OutputTokens > 0 || response.CacheHitTokens > 0},
		ProviderEvent{Type: ProviderEventCompleted},
	)
	return &sliceProviderStream{events: events}, nil
}

func (m *MockProvider) Chat(ctx context.Context, request ChatRequest) (ChatResponse, error) {
	if err := ctx.Err(); err != nil {
		return ChatResponse{}, err
	}
	m.Requests = append(m.Requests, request)
	return m.Response, m.Err
}

type sliceProviderStream struct {
	events []ProviderEvent
	index  int
	closed bool
}

func (s *sliceProviderStream) Next(ctx context.Context) (ProviderEvent, error) {
	if err := ctx.Err(); err != nil {
		return ProviderEvent{}, err
	}
	if s.closed || s.index >= len(s.events) {
		return ProviderEvent{}, errors.New("provider stream closed")
	}
	event := s.events[s.index]
	s.index++
	return event, nil
}

func (s *sliceProviderStream) Close() error {
	s.closed = true
	return nil
}
