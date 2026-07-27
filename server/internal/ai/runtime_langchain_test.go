package ai

import (
	"context"
	"io"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type fakeLangChainRAG struct {
	events []PolicyRAGEvent
	stream PolicyRAGEventStream
}

func (f *fakeLangChainRAG) QueryPolicy(context.Context, PolicyRAGInput) (PolicyRAGResult, error) {
	return PolicyRAGResult{}, nil
}

func (f *fakeLangChainRAG) StreamPolicy(_ context.Context, input PolicyRAGInput) (PolicyRAGEventStream, error) {
	if f.stream != nil {
		return f.stream, nil
	}
	events := make([]PolicyRAGEvent, len(f.events))
	copy(events, f.events)
	for index := range events {
		events[index].RequestID = input.RequestID
		if events[index].Result != nil {
			result := *events[index].Result
			result.RequestID = input.RequestID
			events[index].Result = &result
		}
	}
	return &slicePolicyRAGStream{events: events}, nil
}

type slicePolicyRAGStream struct {
	events []PolicyRAGEvent
	index  int
}

func (s *slicePolicyRAGStream) Next(ctx context.Context) (PolicyRAGEvent, error) {
	if err := ctx.Err(); err != nil {
		return PolicyRAGEvent{}, err
	}
	if s.index >= len(s.events) {
		return PolicyRAGEvent{}, io.EOF
	}
	event := s.events[s.index]
	s.index++
	return event, nil
}

func (s *slicePolicyRAGStream) Close() error { return nil }

type blockingPolicyRAGStream struct {
	once      sync.Once
	cancelled chan struct{}
}

func (s *blockingPolicyRAGStream) Next(ctx context.Context) (PolicyRAGEvent, error) {
	<-ctx.Done()
	s.once.Do(func() { close(s.cancelled) })
	return PolicyRAGEvent{}, ctx.Err()
}

func (s *blockingPolicyRAGStream) Close() error { return nil }

func newLangChainTestRuntime(t *testing.T, client LangChainRAG) (*Runtime, *gorm.DB) {
	t.Helper()
	db := newRuntimeTestDB(t)
	runtime, err := NewRuntime(db, nil, nil, NewEventBroker(), RuntimeConfig{
		ProviderName: "langchain", Model: "python-policy-rag", RequestTimeout: 5 * time.Second,
		MaxMessageChars: 20, HourlyMessageLimit: 3,
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
		AuditHashSecret: "test-secret", LangChainRAGEnabled: true,
	}, WithLangChainRAG(client))
	require.NoError(t, err)
	return runtime, db
}

func TestLangChainRuntimeUsesPythonResultAndSettlesOnce(t *testing.T) {
	result := validPolicyRAGResult("pending")
	client := &fakeLangChainRAG{events: []PolicyRAGEvent{
		{SchemaVersion: "1.0", ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 1, Type: "planning", Timestamp: time.Now().Format(time.RFC3339Nano)},
		{SchemaVersion: "1.0", ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 2, Type: "retrieving", Timestamp: time.Now().Format(time.RFC3339Nano)},
		{SchemaVersion: "1.0", ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 3, Type: "generating", Timestamp: time.Now().Format(time.RFC3339Nano)},
		{SchemaVersion: "1.0", ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 4, Type: "token", Timestamp: time.Now().Format(time.RFC3339Nano), Delta: result.Answer},
		{SchemaVersion: "1.0", ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 5, Type: "completed", Timestamp: time.Now().Format(time.RFC3339Nano), Result: &result},
	}}
	runtime, db := newLangChainTestRuntime(t, client)
	run, _, err := runtime.CreateRun(context.Background(), 31, CreateRunRequest{
		ClientRequestID: uuid.NewString(), Message: "怎么请假",
	})
	require.NoError(t, err)

	completed := waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	require.Equal(t, "fake", completed.Provider)
	require.Equal(t, "fake-v1", completed.Model)
	var usage []models.AIUsageRecord
	require.NoError(t, db.Where("run_id = ?", run.ID).Find(&usage).Error)
	require.Len(t, usage, 1)
	require.Equal(t, 20, usage[0].InputTokens)
	require.Equal(t, 8, usage[0].OutputTokens)
	var events []models.AIEvent
	require.NoError(t, db.Where("run_id = ? AND type = ?", run.ID, "rag.completed").Find(&events).Error)
	require.Len(t, events, 1)
}

func TestLangChainRuntimeCancelPropagatesAndReleasesReservation(t *testing.T) {
	blocking := &blockingPolicyRAGStream{cancelled: make(chan struct{})}
	runtime, db := newLangChainTestRuntime(t, &fakeLangChainRAG{stream: blocking})
	run, _, err := runtime.CreateRun(context.Background(), 32, CreateRunRequest{
		ClientRequestID: uuid.NewString(), Message: "怎么请假",
	})
	require.NoError(t, err)
	waitRunState(t, db, run.ID, models.AIRunStateRetrieving)
	_, err = runtime.Cancel(context.Background(), 32, run.ID)
	require.NoError(t, err)
	waitRunState(t, db, run.ID, models.AIRunStateCancelled)
	require.Eventually(t, func() bool {
		select {
		case <-blocking.cancelled:
			return true
		default:
			return false
		}
	}, time.Second, 10*time.Millisecond)
	require.Eventually(t, func() bool {
		remaining, _, quotaErr := runtime.Quota(context.Background(), 32)
		return quotaErr == nil && remaining == 3
	}, time.Second, 10*time.Millisecond)
}
