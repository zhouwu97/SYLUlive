package ai

import (
	"context"
	"errors"
	"testing"
)

func TestMockProviderHonorsContextCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	provider := &MockProvider{}
	_, err := provider.Chat(ctx, ChatRequest{})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("应返回 context.Canceled，实际为 %v", err)
	}
	if len(provider.Requests) != 0 {
		t.Fatal("已取消请求不应进入 Provider")
	}
}
