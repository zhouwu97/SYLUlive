package ai

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDeepSeekProviderContract(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/chat/completions" || r.Header.Get("Authorization") != "Bearer server-secret" {
			t.Fatalf("DeepSeek 请求不符合契约: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"回答"}}],"usage":{"prompt_tokens":12,"completion_tokens":3}}`))
	}))
	defer server.Close()
	provider, err := NewDeepSeekProvider(server.URL, "server-secret", "deepseek-chat", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	response, err := provider.Chat(context.Background(), ChatRequest{Messages: []Message{{Role: "user", Content: "问题"}}})
	if err != nil {
		t.Fatal(err)
	}
	if response.Content != "回答" || response.InputTokens != 12 || response.OutputTokens != 3 {
		t.Fatalf("响应解析错误: %#v", response)
	}
}

func TestDeepSeekProviderErrorDoesNotExposeResponseBody(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"secret":"remote-sensitive-detail"}`))
	}))
	defer server.Close()
	provider, err := NewDeepSeekProvider(server.URL, "server-secret", "deepseek-chat", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	_, err = provider.Chat(context.Background(), ChatRequest{})
	if err == nil || strings.Contains(err.Error(), "remote-sensitive-detail") {
		t.Fatalf("错误不应泄露远端响应体: %v", err)
	}
}

func TestDeepSeekProviderStreamingContract(t *testing.T) {
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
	provider, err := NewDeepSeekProvider(server.URL, "server-secret", "deepseek-chat", server.Client())
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

func TestDeepSeekProviderPreservesLengthFinishReason(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"未完成回答\"}}]}\n\n"))
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n"))
		_, _ = w.Write([]byte("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":800}}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer server.Close()

	provider, err := NewDeepSeekProvider(server.URL, "server-secret", "deepseek-chat", server.Client())
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
