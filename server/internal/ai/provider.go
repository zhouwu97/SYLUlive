package ai

import "context"

// Message 是与具体模型厂商无关的对话消息。
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// ChatRequest 描述一次受 Context 控制的模型生成请求。
type ChatRequest struct {
	Messages    []Message
	Temperature float64
	MaxTokens   int
}

// ChatResponse 保留业务需要的最小响应与计量信息。
type ChatResponse struct {
	Content      string
	InputTokens  int
	OutputTokens int
}

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

func (m *MockProvider) Chat(ctx context.Context, request ChatRequest) (ChatResponse, error) {
	if err := ctx.Err(); err != nil {
		return ChatResponse{}, err
	}
	m.Requests = append(m.Requests, request)
	return m.Response, m.Err
}
