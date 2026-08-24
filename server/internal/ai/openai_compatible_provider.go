package ai

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

const maxProviderResponseBytes = 2 << 20

type OpenAICompatibleProvider struct {
	endpoint   string
	apiKey     string
	model      string
	httpClient *http.Client
}

func (p *OpenAICompatibleProvider) Name() string { return "openai-compatible" }

func (p *OpenAICompatibleProvider) Capabilities() ProviderCapabilities {
	return ProviderCapabilities{
		Streaming: true, ToolCalls: true, JSONSchema: true, ReasoningContent: true,
		PromptCache: true, UsageInStream: true, ForcedToolChoice: true,
	}
}

func NewOpenAICompatibleProvider(baseURL, apiKey, model string, client *http.Client) (*OpenAICompatibleProvider, error) {
	parsed, err := url.Parse(strings.TrimRight(strings.TrimSpace(baseURL), "/"))
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil {
		return nil, fmt.Errorf("OpenAI-compatible base URL must be HTTPS")
	}
	if strings.TrimSpace(apiKey) == "" || strings.TrimSpace(model) == "" {
		return nil, fmt.Errorf("OpenAI-compatible API key and model are required")
	}
	if client == nil {
		client = http.DefaultClient
	}
	return &OpenAICompatibleProvider{
		endpoint: parsed.String() + "/chat/completions", apiKey: strings.TrimSpace(apiKey),
		model: strings.TrimSpace(model), httpClient: client,
	}, nil
}

func (p *OpenAICompatibleProvider) Chat(ctx context.Context, request ChatRequest) (ChatResponse, error) {
	if err := ctx.Err(); err != nil {
		return ChatResponse{}, err
	}
	payload := struct {
		Model       string    `json:"model"`
		Messages    []Message `json:"messages"`
		Temperature float64   `json:"temperature,omitempty"`
		MaxTokens   int       `json:"max_tokens,omitempty"`
	}{p.model, request.Messages, request.Temperature, request.MaxTokens}
	body, err := json.Marshal(payload)
	if err != nil {
		return ChatResponse{}, err
	}
	httpRequest, err := http.NewRequestWithContext(ctx, http.MethodPost, p.endpoint, bytes.NewReader(body))
	if err != nil {
		return ChatResponse{}, err
	}
	httpRequest.Header.Set("Authorization", "Bearer "+p.apiKey)
	httpRequest.Header.Set("Content-Type", "application/json")
	response, err := p.httpClient.Do(httpRequest)
	if err != nil {
		return ChatResponse{}, err
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, maxProviderResponseBytes+1))
	if err != nil {
		return ChatResponse{}, err
	}
	if len(responseBody) > maxProviderResponseBytes {
		return ChatResponse{}, fmt.Errorf("provider response exceeds limit")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return ChatResponse{}, fmt.Errorf("provider returned HTTP %d", response.StatusCode)
	}
	var decoded struct {
		Choices []struct {
			Message Message `json:"message"`
		} `json:"choices"`
		Usage struct {
			PromptTokens     int `json:"prompt_tokens"`
			CompletionTokens int `json:"completion_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(responseBody, &decoded); err != nil {
		return ChatResponse{}, fmt.Errorf("decode provider response: %w", err)
	}
	if len(decoded.Choices) == 0 {
		return ChatResponse{}, fmt.Errorf("provider returned no choices")
	}
	return ChatResponse{
		Content:     decoded.Choices[0].Message.Content,
		InputTokens: decoded.Usage.PromptTokens, OutputTokens: decoded.Usage.CompletionTokens,
	}, nil
}

// Start 建立 OpenAI 兼容 SSE 流。reasoning_content 会被解析但主动丢弃，绝不进入客户端或数据库。
func (p *OpenAICompatibleProvider) Start(ctx context.Context, request ProviderRequest) (ProviderStream, error) {
	if err := ctx.Err(); err != nil {
		return nil, &ProviderError{Class: ProviderErrorCancelled, Err: err}
	}
	type openAICompatibleTool struct {
		Type     string         `json:"type"`
		Function ToolDefinition `json:"function"`
	}
	type openAICompatibleToolChoice struct {
		Type     string `json:"type"`
		Function struct {
			Name string `json:"name"`
		} `json:"function"`
	}
	tools := make([]openAICompatibleTool, 0, len(request.Tools))
	for _, tool := range request.Tools {
		tools = append(tools, openAICompatibleTool{Type: "function", Function: tool})
	}
	payload := struct {
		Model         string                      `json:"model"`
		Messages      []Message                   `json:"messages"`
		Temperature   float64                     `json:"temperature,omitempty"`
		MaxTokens     int                         `json:"max_tokens,omitempty"`
		Stream        bool                        `json:"stream"`
		StreamOptions map[string]bool             `json:"stream_options"`
		Tools         []openAICompatibleTool      `json:"tools,omitempty"`
		ToolChoice    *openAICompatibleToolChoice `json:"tool_choice,omitempty"`
	}{
		Model: p.model, Messages: request.Messages, Temperature: request.Temperature,
		MaxTokens: request.MaxTokens, Stream: true,
		StreamOptions: map[string]bool{"include_usage": true}, Tools: tools,
	}
	if request.RequiredTool != "" {
		payload.ToolChoice = &openAICompatibleToolChoice{Type: "function"}
		payload.ToolChoice.Function.Name = request.RequiredTool
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, &ProviderError{Class: ProviderErrorInvalid, Err: err}
	}
	httpRequest, err := http.NewRequestWithContext(ctx, http.MethodPost, p.endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, &ProviderError{Class: ProviderErrorInvalid, Err: err}
	}
	httpRequest.Header.Set("Authorization", "Bearer "+p.apiKey)
	httpRequest.Header.Set("Content-Type", "application/json")
	httpRequest.Header.Set("Accept", "text/event-stream")
	response, err := p.httpClient.Do(httpRequest)
	if err != nil {
		return nil, classifyProviderTransportError(ctx, err)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 32<<10))
		_ = response.Body.Close()
		return nil, providerHTTPError(response.StatusCode)
	}
	return &openAICompatibleStream{body: response.Body, scanner: newProviderScanner(response.Body), toolCalls: make(map[int]streamToolCall)}, nil
}

type openAICompatibleStream struct {
	body         io.ReadCloser
	scanner      *bufio.Scanner
	pending      []ProviderEvent
	toolCalls    map[int]streamToolCall
	finishReason string
	closed       bool
}

type streamToolCall struct {
	id      string
	name    string
	started bool
}

func newProviderScanner(reader io.Reader) *bufio.Scanner {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 32<<10), maxProviderResponseBytes)
	return scanner
}

func (s *openAICompatibleStream) Next(ctx context.Context) (ProviderEvent, error) {
	if err := ctx.Err(); err != nil {
		return ProviderEvent{}, &ProviderError{Class: ProviderErrorCancelled, Err: err}
	}
	if len(s.pending) > 0 {
		event := s.pending[0]
		s.pending = s.pending[1:]
		return event, nil
	}
	for s.scanner.Scan() {
		line := strings.TrimSpace(s.scanner.Text())
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "[DONE]" {
			return ProviderEvent{Type: ProviderEventCompleted, FinishReason: s.finishReason}, nil
		}
		var chunk struct {
			Choices []struct {
				Delta struct {
					Content          string `json:"content"`
					ReasoningContent string `json:"reasoning_content"`
					ToolCalls        []struct {
						Index    int    `json:"index"`
						ID       string `json:"id"`
						Function struct {
							Name      string `json:"name"`
							Arguments string `json:"arguments"`
						} `json:"function"`
					} `json:"tool_calls"`
				} `json:"delta"`
				FinishReason *string `json:"finish_reason"`
			} `json:"choices"`
			Usage *struct {
				PromptTokens         int `json:"prompt_tokens"`
				CompletionTokens     int `json:"completion_tokens"`
				PromptCacheHitTokens int `json:"prompt_cache_hit_tokens"`
			} `json:"usage"`
		}
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			return ProviderEvent{}, &ProviderError{Class: ProviderErrorInvalid, Err: err}
		}
		if chunk.Usage != nil {
			s.pending = append(s.pending, ProviderEvent{Type: ProviderEventUsage, InputTokens: chunk.Usage.PromptTokens, OutputTokens: chunk.Usage.CompletionTokens, CacheHitTokens: chunk.Usage.PromptCacheHitTokens, UsageAvailable: true})
		}
		for _, choice := range chunk.Choices {
			if choice.FinishReason != nil {
				s.finishReason = strings.ToLower(strings.TrimSpace(*choice.FinishReason))
			}
			if choice.Delta.Content != "" {
				s.pending = append(s.pending, ProviderEvent{Type: ProviderEventTextDelta, Text: choice.Delta.Content})
			}
			for _, call := range choice.Delta.ToolCalls {
				metadata := s.toolCalls[call.Index]
				if call.ID != "" {
					metadata.id = call.ID
				}
				if call.Function.Name != "" {
					metadata.name = call.Function.Name
				}
				if !metadata.started && metadata.id != "" && metadata.name != "" {
					metadata.started = true
					s.pending = append(s.pending, ProviderEvent{Type: ProviderEventToolCallStarted, CallID: metadata.id, ToolName: metadata.name})
				}
				s.toolCalls[call.Index] = metadata
				if call.Function.Arguments != "" {
					s.pending = append(s.pending, ProviderEvent{Type: ProviderEventToolArgumentsDelta, CallID: metadata.id, ToolName: metadata.name, ArgumentsDelta: call.Function.Arguments})
				}
			}
		}
		if len(s.pending) > 0 {
			event := s.pending[0]
			s.pending = s.pending[1:]
			return event, nil
		}
	}
	if err := s.scanner.Err(); err != nil {
		return ProviderEvent{}, classifyProviderTransportError(ctx, err)
	}
	return ProviderEvent{}, &ProviderError{Class: ProviderErrorInvalid, Err: io.ErrUnexpectedEOF}
}

func (s *openAICompatibleStream) Close() error {
	if s.closed {
		return nil
	}
	s.closed = true
	return s.body.Close()
}

func providerHTTPError(status int) error {
	class := ProviderErrorUnknown
	switch {
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		class = ProviderErrorAuthentication
	case status == http.StatusTooManyRequests:
		class = ProviderErrorRateLimited
	case status == http.StatusRequestTimeout || status == http.StatusGatewayTimeout:
		class = ProviderErrorTimeout
	case status >= 500:
		class = ProviderErrorUnavailable
	case status == http.StatusBadRequest || status == http.StatusUnprocessableEntity:
		class = ProviderErrorRequestRejected
	}
	return &ProviderError{Class: class, Err: fmt.Errorf("provider HTTP %d", status)}
}

func classifyProviderTransportError(ctx context.Context, err error) error {
	if ctx.Err() != nil {
		return &ProviderError{Class: ProviderErrorCancelled, Err: ctx.Err()}
	}
	if timeout, ok := err.(interface{ Timeout() bool }); ok && timeout.Timeout() {
		return &ProviderError{Class: ProviderErrorTimeout, Err: err}
	}
	return &ProviderError{Class: ProviderErrorUnavailable, Err: err}
}
