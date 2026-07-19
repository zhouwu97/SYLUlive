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
