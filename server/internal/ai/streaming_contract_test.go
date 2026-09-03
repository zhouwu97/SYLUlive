package ai

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
)

// blockingDeltaProvider 在首个文本增量后暂停，专门验证增量不会被完成事件阻塞。
type blockingDeltaProvider struct {
	startReady  chan struct{}
	allowStart  chan struct{}
	allowFinish chan struct{}
	startOnce   sync.Once
}

func newBlockingDeltaProvider() *blockingDeltaProvider {
	return &blockingDeltaProvider{
		startReady:  make(chan struct{}),
		allowStart:  make(chan struct{}),
		allowFinish: make(chan struct{}),
	}
}

func (p *blockingDeltaProvider) Name() string { return "blocking-delta" }

func (p *blockingDeltaProvider) Capabilities() ProviderCapabilities {
	return ProviderCapabilities{Streaming: true, UsageInStream: true}
}

func (p *blockingDeltaProvider) Start(ctx context.Context, _ ProviderRequest) (ProviderStream, error) {
	p.startOnce.Do(func() { close(p.startReady) })
	select {
	case <-p.allowStart:
		return &blockingDeltaStream{allowFinish: p.allowFinish}, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

type blockingDeltaStream struct {
	allowFinish <-chan struct{}
	index       int
}

func (s *blockingDeltaStream) Next(ctx context.Context) (ProviderEvent, error) {
	switch s.index {
	case 0:
		s.index++
		return ProviderEvent{Type: ProviderEventTextDelta, Text: "首个增量"}, nil
	case 1:
		s.index++
		select {
		case <-s.allowFinish:
			return ProviderEvent{Type: ProviderEventCompleted, FinishReason: "stop"}, nil
		case <-ctx.Done():
			return ProviderEvent{}, ctx.Err()
		}
	default:
		return ProviderEvent{}, errors.New("provider stream exhausted")
	}
}

func (s *blockingDeltaStream) Close() error { return nil }

func TestRuntimeBroadcastsFirstDeltaBeforeProviderCompletion(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := newBlockingDeltaProvider()
	runtime := newTestRuntime(t, db, provider, fixedRetriever{result: RetrievalResult{}})

	run, _, err := runtime.CreateRun(context.Background(), 23, CreateRunRequest{
		ClientRequestID: uuid.NewString(),
		Message:         "你好",
	})
	require.NoError(t, err)

	select {
	case <-provider.startReady:
	case <-time.After(time.Second):
		t.Fatal("Provider 未进入可控启动点")
	}
	subscription, unsubscribe := runtime.Broker().Subscribe(run.ID)
	defer unsubscribe()
	close(provider.allowStart)

	var delta RunEvent
	deadline := time.After(time.Second)
	for {
		select {
		case event, ok := <-subscription:
			require.True(t, ok, "Provider 完成前订阅不应被关闭")
			if event.Type == "answer.delta" {
				delta = event
				goto gotDelta
			}
		case <-deadline:
			t.Fatal("Provider 未完成前未收到 answer.delta")
		}
	}

gotDelta:
	require.Equal(t, "answer.delta", delta.Type)
	require.Equal(t, "首个增量", eventPayloadText(t, delta))
	require.False(t, delta.Persisted, "在线增量不应被当作持久化事件")

	select {
	case event := <-subscription:
		require.NotEqual(t, "run.completed", event.Type, "Provider 完成前不应先收到终态事件")
	default:
	}
	current, err := runtime.GetRun(context.Background(), 23, run.ID)
	require.NoError(t, err)
	require.NotEqual(t, models.AIRunStateCompleted, current.State, "首个增量到达时 Run 不应已完成")

	close(provider.allowFinish)
	completed := waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	require.Equal(t, "首个增量", completed.AnswerCheckpoint)

	var deltaCount int64
	require.NoError(t, db.Model(&models.AIEvent{}).
		Where("run_id = ? AND type = ?", run.ID, "answer.delta").Count(&deltaCount).Error)
	require.Zero(t, deltaCount, "在线增量不得以 answer.delta 持久化")
}
