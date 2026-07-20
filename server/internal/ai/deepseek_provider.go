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

type DeepSeekProvider struct {
	endpoint   string
	apiKey     string
	model      string
	httpClient *http.Client
}

func (p *DeepSeekProvider) Name() string { return "deepseek" }

func (p *DeepSeekProvider) Capabilities() ProviderCapabilities {
	return ProviderCapabilities{
		Streaming: true, ToolCalls: true, JSONSchema: true, ReasoningContent: true,
		PromptCache: true, UsageInStream: true,
	}
}

func NewDeepSeekProvider(baseURL, apiKey, model string, client *http.Client) (*DeepSeekProvider, error) {
	parsed, err := url.Parse(strings.TrimRight(strings.TrimSpace(baseURL), "/"))
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil {
		return nil, fmt.Errorf("DeepSeek base URL must be HTTPS")
	}
	if strings.TrimSpace(apiKey) == "" || strings.TrimSpace(model) == "" {
		return nil, fmt.Errorf("DeepSeek API key and model are required")
	}
	if client == nil {
		client = http.DefaultClient
	}
	return &DeepSeekProvider{
		endpoint: parsed.String() + "/chat/completions", apiKey: strings.TrimSpace(apiKey),
		model: strings.TrimSpace(model), httpClient: client,
	}, nil
}

func (p *DeepSeekProvider) Chat(ctx context.Context, request ChatRequest) (ChatResponse, error) {
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
		return ChatResponse{}, fmt.Errorf("DeepSeek response exceeds limit")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return ChatResponse{}, fmt.Errorf("DeepSeek returned HTTP %d", response.StatusCode)
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
		return ChatResponse{}, fmt.Errorf("decode DeepSeek response: %w", err)
	}
	if len(decoded.Choices) == 0 {
		return ChatResponse{}, fmt.Errorf("DeepSeek returned no choices")
	}
	return ChatResponse{
		Content:     decoded.Choices[0].Message.Content,
		InputTokens: decoded.Usage.PromptTokens, OutputTokens: decoded.Usage.CompletionTokens,
	}, nil
}

// Start 建立 DeepSeek SSE 流。reasoning_content 会被解析但主动丢弃，绝不进入客户端或数据库。
func (p *DeepSeekProvider) Start(ctx context.Context, request ProviderRequest) (ProviderStream, error) {
	if err := ctx.Err(); err != nil {
		return nil, &ProviderError{Class: ProviderErrorCancelled, Err: err}
	}
	type deepSeekTool struct {
		Type     string         `json:"type"`
		Function ToolDefinition `json:"function"`
	}
	tools := make([]deepSeekTool, 0, len(request.Tools))
	for _, tool := range request.Tools {
		tools = append(tools, deepSeekTool{Type: "function", Function: tool})
	}
	payload := struct {
		Model         string          `json:"model"`
		Messages      []Message       `json:"messages"`
		Temperature   float64         `json:"temperature,omitempty"`
		MaxTokens     int             `json:"max_tokens,omitempty"`
		Stream        bool            `json:"stream"`
		StreamOptions map[string]bool `json:"stream_options"`
		Tools         []deepSeekTool  `json:"tools,omitempty"`
	}{
		Model: p.model, Messages: request.Messages, Temperature: request.Temperature,
		MaxTokens: request.MaxTokens, Stream: true,
		StreamOptions: map[string]bool{"include_usage": true}, Tools: tools,
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
	return &deepSeekStream{body: response.Body, scanner: newProviderScanner(response.Body)}, nil
}

type deepSeekStream struct {
	body    io.ReadCloser
	scanner *bufio.Scanner
	pending []ProviderEvent
	closed  bool
}

func newProviderScanner(reader io.Reader) *bufio.Scanner {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 32<<10), maxProviderResponseBytes)
	return scanner
}

func (s *deepSeekStream) Next(ctx context.Context) (ProviderEvent, error) {
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
			return ProviderEvent{Type: ProviderEventCompleted}, nil
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
			s.pending = append(s.pending, ProviderEvent{Type: ProviderEventUsage, InputTokens: chunk.Usage.PromptTokens, OutputTokens: chunk.Usage.CompletionTokens, CacheHitTokens: chunk.Usage.PromptCacheHitTokens})
		}
		for _, choice := range chunk.Choices {
			if choice.Delta.Content != "" {
				s.pending = append(s.pending, ProviderEvent{Type: ProviderEventTextDelta, Text: choice.Delta.Content})
			}
			for _, call := range choice.Delta.ToolCalls {
				if call.ID != "" || call.Function.Name != "" {
					s.pending = append(s.pending, ProviderEvent{Type: ProviderEventToolCallStarted, CallID: call.ID, ToolName: call.Function.Name})
				}
				if call.Function.Arguments != "" {
					s.pending = append(s.pending, ProviderEvent{Type: ProviderEventToolArgumentsDelta, CallID: call.ID, ToolName: call.Function.Name, ArgumentsDelta: call.Function.Arguments})
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

func (s *deepSeekStream) Close() error {
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
		class = ProviderErrorRejected
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
