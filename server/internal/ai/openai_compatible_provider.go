package ai

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const maxProviderResponseBytes = 2 << 20

type OpenAICompatibleProvider struct {
	endpoint             string
	apiKey               string
	model                string
	reasoningEffort      string
	httpClient           *http.Client
	firstProgressTimeout time.Duration
	fallbackModel        string
}

type OpenAICompatibleProviderOption func(*OpenAICompatibleProvider)

func WithOpenAICompatibleFallbackModel(model string) OpenAICompatibleProviderOption {
	return func(p *OpenAICompatibleProvider) { p.fallbackModel = strings.TrimSpace(model) }
}

func (p *OpenAICompatibleProvider) Name() string { return "openai-compatible" }

func (p *OpenAICompatibleProvider) Capabilities() ProviderCapabilities {
	return ProviderCapabilities{
		Streaming: true, ToolCalls: true, JSONSchema: true, ReasoningContent: true,
		PromptCache: true, UsageInStream: true, ForcedToolChoice: true,
	}
}

func NewOpenAICompatibleProvider(baseURL, apiKey, model, reasoningEffort string, client *http.Client, options ...OpenAICompatibleProviderOption) (*OpenAICompatibleProvider, error) {
	parsed, err := url.Parse(strings.TrimRight(strings.TrimSpace(baseURL), "/"))
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil {
		return nil, fmt.Errorf("OpenAI-compatible base URL must be HTTPS")
	}
	if strings.TrimSpace(apiKey) == "" || strings.TrimSpace(model) == "" {
		return nil, fmt.Errorf("OpenAI-compatible API key and model are required")
	}
	reasoningEffort = strings.ToLower(strings.TrimSpace(reasoningEffort))
	switch reasoningEffort {
	case "", "none", "low", "medium", "high", "xhigh", "max":
	default:
		return nil, fmt.Errorf("unsupported reasoning effort")
	}
	if client == nil {
		client = http.DefaultClient
	}
	provider := &OpenAICompatibleProvider{
		endpoint: parsed.String() + "/chat/completions", apiKey: strings.TrimSpace(apiKey),
		model: strings.TrimSpace(model), reasoningEffort: reasoningEffort, httpClient: client,
		firstProgressTimeout: 20 * time.Second,
	}
	for _, option := range options {
		option(provider)
	}
	return provider, nil
}

func (p *OpenAICompatibleProvider) Chat(ctx context.Context, request ChatRequest) (ChatResponse, error) {
	if err := ctx.Err(); err != nil {
		return ChatResponse{}, err
	}
	payload := struct {
		Model           string    `json:"model"`
		Messages        []Message `json:"messages"`
		Temperature     float64   `json:"temperature,omitempty"`
		MaxTokens       int       `json:"max_tokens,omitempty"`
		ReasoningEffort string    `json:"reasoning_effort,omitempty"`
	}{p.model, request.Messages, request.Temperature, request.MaxTokens, p.reasoningEffort}
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
	httpRequest.Header.Set("X-Request-ID", requestIDForContext(ctx))
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
		return ChatResponse{}, providerHTTPError(response.StatusCode, responseBody)
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
		return nil, classifyProviderTransportError(ctx, err)
	}
	model := p.model
	// 同一 Run 已切换备用模型时，后续工具回合沿用备用，避免反复消耗首包时限。
	if request.Model != "" && request.Model == p.fallbackModel {
		model = p.fallbackModel
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
		Model           string                      `json:"model"`
		Messages        []Message                   `json:"messages"`
		Temperature     float64                     `json:"temperature,omitempty"`
		MaxTokens       int                         `json:"max_tokens,omitempty"`
		Stream          bool                        `json:"stream"`
		StreamOptions   map[string]bool             `json:"stream_options"`
		Tools           []openAICompatibleTool      `json:"tools,omitempty"`
		ToolChoice      *openAICompatibleToolChoice `json:"tool_choice,omitempty"`
		ReasoningEffort string                      `json:"reasoning_effort,omitempty"`
	}{
		Model: model, Messages: request.Messages, Temperature: request.Temperature,
		MaxTokens: request.MaxTokens, Stream: true,
		StreamOptions: map[string]bool{"include_usage": true}, Tools: tools,
		ReasoningEffort: p.reasoningEffort,
	}
	if request.RequiredTool != "" {
		payload.ToolChoice = &openAICompatibleToolChoice{Type: "function"}
		payload.ToolChoice.Function.Name = request.RequiredTool
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, &ProviderError{Class: ProviderErrorInvalid, Err: err}
	}
	return p.startWithRecovery(ctx, body, model)
}

// 网关可能仅发送保活而不启动生成；只有尚无模型进展的请求才允许重试一次。
// 思考内容也算进展，避免中断 medium 推理；内容本身仍不向业务层暴露。
func (p *OpenAICompatibleProvider) startWithRecovery(ctx context.Context, body []byte, model string) (ProviderStream, error) {
	for attempt := 0; ; attempt++ {
		attemptCtx, cancel := context.WithCancelCause(ctx)
		timer := time.AfterFunc(p.firstProgressTimeout, func() { cancel(context.DeadlineExceeded) })
		stream, err := p.startStream(attemptCtx, body, func() { timer.Stop() })
		var first ProviderEvent
		if err == nil {
			stream.model = model
			first, err = stream.Next(attemptCtx)
		}
		timer.Stop()
		if err == nil {
			stream.pending = append([]ProviderEvent{first}, stream.pending...)
			stream.cancel = func() { cancel(context.Canceled) }
			return stream, nil
		}
		cancel(context.Canceled)
		if stream != nil {
			_ = stream.Close()
		}
		if ctx.Err() != nil {
			return nil, classifyProviderTransportError(ctx, ctx.Err())
		}
		class := providerErrorClass(err)
		if attempt > 0 || (stream != nil && stream.progress) || (class != ProviderErrorTimeout && class != ProviderErrorUnavailable) {
			return nil, err
		}
		nextModel := model
		if p.fallbackModel != "" {
			nextModel = p.fallbackModel
		}
		log.Printf("[AI_PROVIDER_EMPTY_STREAM_RETRY] request_id=%s attempt=2 cause=%s from_model=%s to_model=%s", requestIDForContext(ctx), class, model, nextModel)
		if nextModel != model {
			var payload map[string]json.RawMessage
			if err := json.Unmarshal(body, &payload); err != nil {
				return nil, &ProviderError{Class: ProviderErrorInvalid, Err: err}
			}
			payload["model"], _ = json.Marshal(nextModel)
			body, err = json.Marshal(payload)
			if err != nil {
				return nil, &ProviderError{Class: ProviderErrorInvalid, Err: err}
			}
			model = nextModel
		}
	}
}

func (p *OpenAICompatibleProvider) startStream(ctx context.Context, body []byte, onProgress func()) (*openAICompatibleStream, error) {
	httpRequest, err := http.NewRequestWithContext(ctx, http.MethodPost, p.endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, &ProviderError{Class: ProviderErrorInvalid, Err: err}
	}
	httpRequest.Header.Set("Authorization", "Bearer "+p.apiKey)
	httpRequest.Header.Set("Content-Type", "application/json")
	httpRequest.Header.Set("Accept", "text/event-stream")
	httpRequest.Header.Set("X-Request-ID", requestIDForContext(ctx))
	response, err := p.httpClient.Do(httpRequest)
	if err != nil {
		return nil, classifyProviderTransportError(ctx, err)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		responseBody, _ := io.ReadAll(io.LimitReader(response.Body, 32<<10))
		_ = response.Body.Close()
		return nil, providerHTTPError(response.StatusCode, responseBody)
	}
	return &openAICompatibleStream{body: response.Body, scanner: newProviderScanner(response.Body), toolCalls: make(map[int]streamToolCall), onProgress: onProgress}, nil
}

type openAICompatibleStream struct {
	body         io.ReadCloser
	scanner      *bufio.Scanner
	pending      []ProviderEvent
	toolCalls    map[int]streamToolCall
	finishReason string
	closed       bool
	progress     bool
	onProgress   func()
	cancel       context.CancelFunc
	model        string
}

func (s *openAICompatibleStream) markProgress() {
	if !s.progress {
		s.progress = true
		if s.onProgress != nil {
			s.onProgress()
		}
	}
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

func (s *openAICompatibleStream) Next(ctx context.Context) (event ProviderEvent, err error) {
	defer func() { event.Model = s.model }()
	if err := ctx.Err(); err != nil {
		return ProviderEvent{}, classifyProviderTransportError(ctx, err)
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
			s.markProgress()
			return ProviderEvent{Type: ProviderEventCompleted, FinishReason: s.finishReason}, nil
		}
		var chunk struct {
			Error   json.RawMessage `json:"error"`
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
				PromptTokens           int `json:"prompt_tokens"`
				CompletionTokens       int `json:"completion_tokens"`
				PromptCacheHitTokens   int `json:"prompt_cache_hit_tokens"`
				PromptCacheWriteTokens int `json:"prompt_cache_write_tokens"`
				PromptTokensDetails    struct {
					CachedTokens     *int `json:"cached_tokens"`
					CacheWriteTokens *int `json:"cache_creation_tokens"`
				} `json:"prompt_tokens_details"`
			} `json:"usage"`
		}
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			return ProviderEvent{}, &ProviderError{Class: ProviderErrorInvalid, Err: err}
		}
		// HTTP 200 也可能携带流内错误，不能忽略后继续等待到总超时。
		if len(chunk.Error) > 0 && string(chunk.Error) != "null" {
			return ProviderEvent{}, providerHTTPError(http.StatusOK, []byte(data))
		}
		if chunk.Usage != nil {
			s.markProgress()
			cacheRead, cacheWrite := chunk.Usage.PromptCacheHitTokens, chunk.Usage.PromptCacheWriteTokens
			// 标准 cached_tokens 与兼容字段表达同一批缓存，不能重复相加。
			if chunk.Usage.PromptTokensDetails.CachedTokens != nil {
				cacheRead = *chunk.Usage.PromptTokensDetails.CachedTokens
			}
			if chunk.Usage.PromptTokensDetails.CacheWriteTokens != nil {
				cacheWrite = *chunk.Usage.PromptTokensDetails.CacheWriteTokens
			}
			s.pending = append(s.pending, ProviderEvent{Type: ProviderEventUsage, InputTokens: chunk.Usage.PromptTokens, OutputTokens: chunk.Usage.CompletionTokens, CacheHitTokens: cacheRead, CacheWriteTokens: cacheWrite, UsageAvailable: true})
		}
		for _, choice := range chunk.Choices {
			if choice.Delta.Content != "" || choice.Delta.ReasoningContent != "" || len(choice.Delta.ToolCalls) > 0 || choice.FinishReason != nil {
				s.markProgress()
			}
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
	if s.cancel != nil {
		s.cancel()
	}
	return s.body.Close()
}

func providerHTTPError(status int, responseBody ...[]byte) error {
	class := ProviderErrorUnknown
	if len(responseBody) > 0 && providerReportsMissingModel(responseBody[0]) {
		class = ProviderErrorModelUnavailable
		return &ProviderError{Class: class, Err: fmt.Errorf("provider HTTP %d", status)}
	}
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
	case status == http.StatusNotFound:
		class = ProviderErrorRequestRejected
	}
	return &ProviderError{Class: class, Err: fmt.Errorf("provider HTTP %d", status)}
}

func providerReportsMissingModel(body []byte) bool {
	var envelope struct {
		Error struct {
			Code    string `json:"code"`
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return false
	}
	searchable := strings.ToLower(strings.Join([]string{
		envelope.Error.Code,
		envelope.Error.Type,
		envelope.Error.Message,
	}, " "))
	return strings.Contains(searchable, "model_not_found") ||
		strings.Contains(searchable, "model not found") ||
		strings.Contains(searchable, "model is not supported") ||
		strings.Contains(searchable, "not supported by any configured account")
}

func classifyProviderTransportError(ctx context.Context, err error) error {
	// 请求时限耗尽并非用户取消，必须保留超时分类供重试与客户端提示使用。
	if errors.Is(context.Cause(ctx), context.DeadlineExceeded) || errors.Is(err, context.DeadlineExceeded) {
		return &ProviderError{Class: ProviderErrorTimeout, Err: err}
	}
	if ctx.Err() != nil {
		return &ProviderError{Class: ProviderErrorCancelled, Err: ctx.Err()}
	}
	if timeout, ok := err.(interface{ Timeout() bool }); ok && timeout.Timeout() {
		return &ProviderError{Class: ProviderErrorTimeout, Err: err}
	}
	return &ProviderError{Class: ProviderErrorUnavailable, Err: err}
}
