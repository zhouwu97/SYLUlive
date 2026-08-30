package ai

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestOpenAICompatibleProviderForcesRequiredTool(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var payload struct {
			Tools []struct {
				Function ToolDefinition `json:"function"`
			} `json:"tools"`
			ToolChoice struct {
				Function struct {
					Name string `json:"name"`
				} `json:"function"`
			} `json:"tool_choice"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatalf("解析请求失败: %v", err)
		}
		if len(payload.Tools) != 1 || payload.Tools[0].Function.Name != "hy3_decision_analyze_academic" {
			t.Fatalf("工具定义错误: %#v", payload.Tools)
		}
		if payload.ToolChoice.Function.Name != "hy3_decision_analyze_academic" {
			t.Fatalf("未强制所需工具: %#v", payload.ToolChoice)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"hy3_decision_analyze_academic\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer server.Close()
	provider, err := NewOpenAICompatibleProvider(server.URL, "server-secret", "gpt-5.4-mini", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	definition := ToolDefinition{Name: "hy3_decision_analyze_academic", Parameters: map[string]interface{}{"type": "object"}}
	stream, err := provider.Start(context.Background(), ProviderRequest{
		Messages: []Message{{Role: "user", Content: "分析我的学业"}},
		Tools:    []ToolDefinition{definition}, RequiredTool: definition.Name,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	event, err := stream.Next(context.Background())
	if err != nil || event.Type != ProviderEventToolCallStarted || event.ToolName != definition.Name {
		t.Fatalf("tool event = %#v err=%v", event, err)
	}
}

func TestOpenAICompatibleProviderContract(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/chat/completions" || r.Header.Get("Authorization") != "Bearer server-secret" {
			t.Fatalf("OpenAI 兼容请求不符合契约: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"回答"}}],"usage":{"prompt_tokens":12,"completion_tokens":3}}`))
	}))
	defer server.Close()
	provider, err := NewOpenAICompatibleProvider(server.URL, "server-secret", "gpt-5.4-mini", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	if provider.Name() != "openai-compatible" {
		t.Fatalf("Provider 名称错误: %s", provider.Name())
	}
	response, err := provider.Chat(context.Background(), ChatRequest{Messages: []Message{{Role: "user", Content: "问题"}}})
	if err != nil {
		t.Fatal(err)
	}
	if response.Content != "回答" || response.InputTokens != 12 || response.OutputTokens != 3 {
		t.Fatalf("响应解析错误: %#v", response)
	}
}

func TestOpenAICompatibleProviderErrorDoesNotExposeResponseBody(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"secret":"remote-sensitive-detail"}`))
	}))
	defer server.Close()
	provider, err := NewOpenAICompatibleProvider(server.URL, "server-secret", "gpt-5.4-mini", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	_, err = provider.Chat(context.Background(), ChatRequest{})
	if err == nil || strings.Contains(err.Error(), "remote-sensitive-detail") {
		t.Fatalf("错误不应泄露远端响应体: %v", err)
	}
}

func TestOpenAICompatibleProviderDoesNotTreatRequestErrorAsContentRejection(t *testing.T) {
	for _, status := range []int{http.StatusBadRequest, http.StatusNotFound, http.StatusUnprocessableEntity} {
		err := providerHTTPError(status)
		if class := providerErrorClass(err); class != ProviderErrorRequestRejected {
			t.Fatalf("HTTP %d class = %s", status, class)
		}
		if strings.Contains(err.Error(), ProviderErrorRejected) {
			t.Fatalf("HTTP %d 不应被标记为内容拦截: %v", status, err)
		}
	}
}

func TestOpenAICompatibleProviderClassifiesMissingModelWithoutLeakingBody(t *testing.T) {
	body := []byte(`{"error":{"message":"Model secret-model is not supported by any configured account in this group","type":"model_not_found"}}`)
	err := providerHTTPError(http.StatusNotFound, body)
	if class := providerErrorClass(err); class != ProviderErrorModelUnavailable {
		t.Fatalf("missing model class = %s", class)
	}
	if strings.Contains(err.Error(), "secret-model") {
		t.Fatalf("错误不应泄露远端响应体: %v", err)
	}
}

func TestOpenAICompatibleProviderStreamingContract(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		flusher := w.(http.Flusher)
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"回答\",\"reasoning_content\":\"不得返回\"}}]}\n\n"))
		flusher.Flush()
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"))
		_, _ = w.Write([]byte("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":3,\"prompt_cache_hit_tokens\":2}}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer server.Close()
	provider, err := NewOpenAICompatibleProvider(server.URL, "server-secret", "gpt-5.4-mini", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	stream, err := provider.Start(context.Background(), ProviderRequest{Messages: []Message{{Role: "user", Content: "问题"}}})
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	textEvent, err := stream.Next(context.Background())
	if err != nil || textEvent.Type != ProviderEventTextDelta || textEvent.Text != "回答" {
		t.Fatalf("text event = %#v err=%v", textEvent, err)
	}
	if strings.Contains(textEvent.Text, "不得返回") {
		t.Fatal("reasoning_content 不得进入统一事件")
	}
	usageEvent, err := stream.Next(context.Background())
	if err != nil || usageEvent.Type != ProviderEventUsage || usageEvent.CacheHitTokens != 2 {
		t.Fatalf("usage event = %#v err=%v", usageEvent, err)
	}
	completed, err := stream.Next(context.Background())
	if err != nil || completed.Type != ProviderEventCompleted || completed.FinishReason != "stop" {
		t.Fatalf("completed event = %#v err=%v", completed, err)
	}
}

func TestOpenAICompatibleProviderPreservesLengthFinishReason(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"未完成回答\"}}]}\n\n"))
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n"))
		_, _ = w.Write([]byte("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":800}}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer server.Close()

	provider, err := NewOpenAICompatibleProvider(server.URL, "server-secret", "gpt-5.4-mini", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	stream, err := provider.Start(context.Background(), ProviderRequest{Messages: []Message{{Role: "user", Content: "问题"}}})
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()

	textEvent, err := stream.Next(context.Background())
	if err != nil || textEvent.Text != "未完成回答" {
		t.Fatalf("text event = %#v err=%v", textEvent, err)
	}
	usageEvent, err := stream.Next(context.Background())
	if err != nil || usageEvent.OutputTokens != 800 {
		t.Fatalf("usage event = %#v err=%v", usageEvent, err)
	}
	completed, err := stream.Next(context.Background())
	if err != nil || completed.Type != ProviderEventCompleted || completed.FinishReason != "length" {
		t.Fatalf("completed event = %#v err=%v", completed, err)
	}
}
