package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/utils"
)

type fakeLangChainRAG struct {
	events []PolicyRAGEvent
	stream PolicyRAGEventStream
	inputs chan PolicyRAGInput
}

func (f *fakeLangChainRAG) QueryPolicy(context.Context, PolicyRAGInput) (PolicyRAGResult, error) {
	return PolicyRAGResult{}, nil
}

func (f *fakeLangChainRAG) StreamPolicy(_ context.Context, input PolicyRAGInput) (PolicyRAGEventStream, error) {
	if f.inputs != nil {
		f.inputs <- input
	}
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

func seedPolicyHistoryRound(
	t *testing.T,
	db *gorm.DB,
	userID uint,
	conversationID string,
	state string,
	userContent string,
	assistantContent string,
	completedAt time.Time,
) models.AIRun {
	t.Helper()
	run := models.AIRun{
		ID: uuid.NewString(), UserID: userID, ConversationID: conversationID,
		ClientRequestID: uuid.NewString(), State: state, Provider: "fake", Model: "fake-v1",
		MessageHash: "history-hash", MessageLength: len(userContent),
		ExpiresAt: completedAt.Add(time.Hour), CreatedAt: completedAt.Add(-time.Second),
	}
	if state == models.AIRunStateCompleted {
		run.CompletedAt = &completedAt
	}
	require.NoError(t, db.Create(&run).Error)
	require.NoError(t, db.Create(&[]models.AIConversationMessage{
		{
			ID: uuid.NewString(), ConversationID: conversationID, RunID: &run.ID,
			Role: "user", Content: userContent, CreatedAt: completedAt.Add(-time.Second),
		},
		{
			ID: uuid.NewString(), ConversationID: conversationID, RunID: &run.ID,
			Role: "assistant", Content: assistantContent, CreatedAt: completedAt,
		},
	}).Error)
	return run
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
		LangChainRAGRolloutPercent: 100,
	}, WithLangChainRAG(client))
	require.NoError(t, err)
	return runtime, db
}

func TestLangChainRolloutUsesStableAccountBuckets(t *testing.T) {
	runtime := &Runtime{config: RuntimeConfig{
		AuditHashSecret: "stable-rollout-secret", LangChainRAGEnabled: true,
		LangChainRAGRolloutPercent: 20, LegacyRAGEnabled: true,
	}}
	selected := 0
	for userID := uint(1); userID <= 1_000; userID++ {
		first := runtime.useLangChain(userID)
		require.Equal(t, first, runtime.useLangChain(userID))
		if first {
			selected++
		}
	}
	require.Greater(t, selected, 150)
	require.Less(t, selected, 250)
}

func TestLangChainCanaryRequiresLegacyRuntimeDependencies(t *testing.T) {
	db := newRuntimeTestDB(t)
	_, err := NewRuntime(db, nil, nil, NewEventBroker(), RuntimeConfig{
		ProviderName: "rollout", Model: "policy-rag", RequestTimeout: 5 * time.Second,
		MaxMessageChars: 20, HourlyMessageLimit: 3,
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		AuditHashSecret: "test-secret", LangChainRAGEnabled: true,
		LangChainRAGRolloutPercent: 5,
	}, WithLangChainRAG(&fakeLangChainRAG{}))
	require.EqualError(t, err, "legacy AI runtime is required before LangChain reaches 100 percent")
}

func TestLangChainRuntimeUsesPythonResultAndSettlesOnce(t *testing.T) {
	result := validPolicyRAGResult("pending")
	client := &fakeLangChainRAG{events: []PolicyRAGEvent{
		{SchemaVersion: PolicyRAGSchemaVersion, ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 1, Type: "planning", Timestamp: time.Now().Format(time.RFC3339Nano)},
		{SchemaVersion: PolicyRAGSchemaVersion, ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 2, Type: "retrieving", Timestamp: time.Now().Format(time.RFC3339Nano)},
		{SchemaVersion: PolicyRAGSchemaVersion, ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 3, Type: "reranking", Timestamp: time.Now().Format(time.RFC3339Nano)},
		{SchemaVersion: PolicyRAGSchemaVersion, ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 4, Type: "generating", Timestamp: time.Now().Format(time.RFC3339Nano)},
		{SchemaVersion: PolicyRAGSchemaVersion, ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 5, Type: "token", Timestamp: time.Now().Format(time.RFC3339Nano), Delta: result.Answer},
		{SchemaVersion: PolicyRAGSchemaVersion, ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 6, Type: "completed", Timestamp: time.Now().Format(time.RFC3339Nano), Result: &result},
	}}
	runtime, db := newLangChainTestRuntime(t, client)
	seedPublishedKnowledgeSource(t, db, 9, 18)
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

func TestLangChainRuntimePassesOnlyRecentOwnedConversationHistory(t *testing.T) {
	result := validPolicyRAGResult("pending")
	inputs := make(chan PolicyRAGInput, 1)
	client := &fakeLangChainRAG{inputs: inputs, events: []PolicyRAGEvent{
		{SchemaVersion: PolicyRAGSchemaVersion, ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 1, Type: "generating", Timestamp: time.Now().Format(time.RFC3339Nano)},
		{SchemaVersion: PolicyRAGSchemaVersion, ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 2, Type: "token", Timestamp: time.Now().Format(time.RFC3339Nano), Delta: result.Answer},
		{SchemaVersion: PolicyRAGSchemaVersion, ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 3, Type: "completed", Timestamp: time.Now().Format(time.RFC3339Nano), Result: &result},
	}}
	runtime, db := newLangChainTestRuntime(t, client)
	seedPublishedKnowledgeSource(t, db, 9, 18)
	userID := uint(41)
	conversationID := uuid.NewString()
	require.NoError(t, db.Create(&models.AIConversation{ID: conversationID, UserID: userID}).Error)
	now := time.Now().Add(-time.Minute)
	for index := 0; index < 5; index++ {
		seedPolicyHistoryRound(
			t, db, userID, conversationID, models.AIRunStateCompleted,
			fmt.Sprintf("同会话问题-%d", index), fmt.Sprintf("同会话回答-%d", index),
			now.Add(time.Duration(index)*time.Second),
		)
	}
	// 最近的残缺 Run 不能挤占更早但有效的完整轮次。
	seedPolicyHistoryRound(
		t, db, userID, conversationID, models.AIRunStateCompleted,
		"残缺问题-1", "", now.Add(5*time.Second),
	)
	seedPolicyHistoryRound(
		t, db, userID, conversationID, models.AIRunStateCompleted,
		"残缺问题-2", "", now.Add(6*time.Second),
	)
	seedPolicyHistoryRound(
		t, db, userID, conversationID, models.AIRunStateFailed,
		"失败问题", "失败回答", now.Add(10*time.Second),
	)
	otherConversationID := uuid.NewString()
	require.NoError(t, db.Create(&models.AIConversation{ID: otherConversationID, UserID: userID}).Error)
	seedPolicyHistoryRound(
		t, db, userID, otherConversationID, models.AIRunStateCompleted,
		"其他会话问题", "其他会话回答", now.Add(11*time.Second),
	)
	// 即使异常数据把其他账号 Run 指向当前会话，Run 所有者约束也必须将其排除。
	seedPolicyHistoryRound(
		t, db, 99, conversationID, models.AIRunStateCompleted,
		"其他账号问题", "其他账号回答", now.Add(12*time.Second),
	)

	run, _, err := runtime.CreateRun(context.Background(), userID, CreateRunRequest{
		ConversationID: conversationID, ClientRequestID: uuid.NewString(), Message: "那实验课呢",
	})
	require.NoError(t, err)
	received := <-inputs
	require.Equal(t, run.ID, received.RequestID)
	require.Len(t, received.History, policyHistoryMaxMessages)
	require.Equal(t, "同会话问题-1", received.History[0].Content)
	require.Equal(t, "同会话回答-4", received.History[len(received.History)-1].Content)
	serialized, err := json.Marshal(received.History)
	require.NoError(t, err)
	require.NotContains(t, string(serialized), "同会话问题-0")
	require.NotContains(t, string(serialized), "残缺问题")
	require.NotContains(t, string(serialized), "失败问题")
	require.NotContains(t, string(serialized), "其他会话问题")
	require.NotContains(t, string(serialized), "其他账号问题")
	waitRunState(t, db, run.ID, models.AIRunStateCompleted)
}

func TestPolicyHistoryIsDeterministicallyBoundedByCompleteRounds(t *testing.T) {
	runtime, db := newLangChainTestRuntime(t, &fakeLangChainRAG{})
	userID := uint(42)
	conversationID := uuid.NewString()
	require.NoError(t, db.Create(&models.AIConversation{ID: conversationID, UserID: userID}).Error)
	now := time.Now().Add(-time.Minute)
	for index := 0; index < policyHistoryMaxRounds; index++ {
		seedPolicyHistoryRound(
			t, db, userID, conversationID, models.AIRunStateCompleted,
			strings.Repeat(fmt.Sprintf("问%d", index), 200),
			strings.Repeat(fmt.Sprintf("答%d", index), 500),
			now.Add(time.Duration(index)*time.Second),
		)
	}
	current := models.AIRun{ID: uuid.NewString(), UserID: userID, ConversationID: conversationID}

	history, err := runtime.loadPolicyHistory(context.Background(), current)
	require.NoError(t, err)
	require.NotEmpty(t, history)
	require.LessOrEqual(t, len(history), policyHistoryMaxMessages)
	require.Zero(t, len(history)%2)
	total := 0
	for index, item := range history {
		require.Equal(t, []string{"user", "assistant"}[index%2], item.Role)
		total += utils.CountGraphemes(item.Content)
	}
	require.LessOrEqual(t, total, policyHistoryMaxGraphemes)
	require.LessOrEqual(t, utils.CountGraphemes(history[0].Content), policyHistoryMaxUserGraphemes)
	require.LessOrEqual(t, utils.CountGraphemes(history[1].Content), policyHistoryMaxAnswerGraphemes)
}

func TestPolicyHistoryRejectsDeletedConversation(t *testing.T) {
	runtime, db := newLangChainTestRuntime(t, &fakeLangChainRAG{})
	userID := uint(43)
	conversationID := uuid.NewString()
	conversation := models.AIConversation{ID: conversationID, UserID: userID}
	require.NoError(t, db.Create(&conversation).Error)
	seedPolicyHistoryRound(
		t, db, userID, conversationID, models.AIRunStateCompleted,
		"补考成绩怎么算", "应以当前已发布规定为准。", time.Now().Add(-time.Minute),
	)
	require.NoError(t, db.Delete(&conversation).Error)

	history, err := runtime.loadPolicyHistory(context.Background(), models.AIRun{
		ID: uuid.NewString(), UserID: userID, ConversationID: conversationID,
	})

	require.ErrorIs(t, err, gorm.ErrRecordNotFound)
	require.Empty(t, history)
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

func TestLangChainRuntimeRejectsSourceRevokedBeforeFinalValidation(t *testing.T) {
	result := validPolicyRAGResult("pending")
	client := &fakeLangChainRAG{events: []PolicyRAGEvent{
		{SchemaVersion: PolicyRAGSchemaVersion, ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 1, Type: "generating", Timestamp: time.Now().Format(time.RFC3339Nano)},
		{SchemaVersion: PolicyRAGSchemaVersion, ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 2, Type: "token", Timestamp: time.Now().Format(time.RFC3339Nano), Delta: result.Answer},
		{SchemaVersion: PolicyRAGSchemaVersion, ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 3, Type: "completed", Timestamp: time.Now().Format(time.RFC3339Nano), Result: &result},
	}}
	runtime, db := newLangChainTestRuntime(t, client)
	require.NoError(t, db.AutoMigrate(&models.AIKnowledgeDocument{}, &models.AIKnowledgeChunk{}))
	require.NoError(t, db.Create(&models.AIKnowledgeDocument{
		ID: 9, Title: "学生手册", SourceType: "official", Content: "正文", ContentHash: "doc-hash",
		Status: models.KnowledgeStatusRevoked, CreatedBy: 1,
	}).Error)
	require.NoError(t, db.Create(&models.AIKnowledgeChunk{
		ID: 18, DocumentID: 9, ChunkIndex: 0, Content: "学生请假应履行审批手续。",
		ContentHash: "chunk-hash", EmbeddingModelVersion: "fixture-v1",
	}).Error)

	run, _, err := runtime.CreateRun(context.Background(), 33, CreateRunRequest{
		ClientRequestID: uuid.NewString(), Message: "怎么请假",
	})
	require.NoError(t, err)
	waitRunState(t, db, run.ID, models.AIRunStateCompleted)

	var messages []models.AIConversationMessage
	require.NoError(t, db.Where("run_id = ?", run.ID).Order("created_at ASC").Find(&messages).Error)
	require.Len(t, messages, 2)
	require.Equal(t, "当前已发布资料不足，暂时无法给出可核验回答。", messages[1].Content)

	var sourceEvent models.AIEvent
	require.NoError(t, db.Where("run_id = ? AND type = ?", run.ID, "sources.ready").First(&sourceEvent).Error)
	var payload struct {
		Sources []SourceCard `json:"sources"`
	}
	require.NoError(t, json.Unmarshal(sourceEvent.Payload, &payload))
	require.Empty(t, payload.Sources)
}
