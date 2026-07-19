package ai

import (
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
