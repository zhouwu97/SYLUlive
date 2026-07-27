package ai

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type fixedRetriever struct {
	result RetrievalResult
	err    error
}

type staticEventProvider struct {
	events   []ProviderEvent
	requests chan ProviderRequest
}

func (p *staticEventProvider) Name() string { return "static-events" }

func (p *staticEventProvider) Capabilities() ProviderCapabilities {
	return ProviderCapabilities{Streaming: true, UsageInStream: true}
}

func (p *staticEventProvider) Start(_ context.Context, request ProviderRequest) (ProviderStream, error) {
	p.requests <- request
	return &sliceProviderStream{events: p.events}, nil
}

func (r fixedRetriever) Retrieve(context.Context, string) (RetrievalResult, error) {
	return r.result, r.err
}

func newRuntimeTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := fmt.Sprintf("file:%s?mode=memory&cache=shared", uuid.NewString())
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	require.NoError(t, db.AutoMigrate(
		&models.AIConversation{}, &models.AIConversationMessage{}, &models.AIRun{},
		&models.AIEvent{}, &models.AIToolCall{}, &models.AIQuotaEntry{},
		&models.AIUserBudget{}, &models.AIBudgetReservation{}, &models.AIUsageRecord{},
	))
	return db
}

func newTestRuntime(t *testing.T, db *gorm.DB, provider AIProvider, retriever PolicyRetriever) *Runtime {
	t.Helper()
	runtime, err := NewRuntime(db, provider, retriever, NewEventBroker(), RuntimeConfig{
		ProviderName: "mock", Model: "mock", RequestTimeout: 5 * time.Second,
		MaxMessageChars: 20, HourlyMessageLimit: 3,
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
		AuditHashSecret: "test-secret",
	})
	require.NoError(t, err)
	return runtime
}

func seedPublishedKnowledgeSource(t *testing.T, db *gorm.DB, documentID uint, chunkID uint64) {
	t.Helper()
	require.NoError(t, db.AutoMigrate(&models.AIKnowledgeDocument{}, &models.AIKnowledgeChunk{}))
	require.NoError(t, db.Create(&models.AIKnowledgeDocument{
		ID: documentID, Title: "学生手册", SourceType: "official", Content: "正文",
		ContentHash: fmt.Sprintf("doc-%d", documentID), Status: models.KnowledgeStatusPublished, CreatedBy: 1,
	}).Error)
	require.NoError(t, db.Create(&models.AIKnowledgeChunk{
		ID: chunkID, DocumentID: documentID, ChunkIndex: 0, Content: "请假需审批",
		ContentHash: fmt.Sprintf("chunk-%d", chunkID), EmbeddingModelVersion: "fixture-v1",
	}).Error)
}

func waitRunState(t *testing.T, db *gorm.DB, runID string, states ...string) models.AIRun {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		var run models.AIRun
		if err := db.First(&run, "id = ?", runID).Error; err == nil {
			for _, state := range states {
				if run.State == state {
					return run
				}
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("run %s did not reach states %v", runID, states)
	return models.AIRun{}
}

func TestNormalizeUserMessageCountsGraphemeClusters(t *testing.T) {
	message, count, err := NormalizeUserMessage("  👨‍👩‍👧‍👦\n\n请假  ", 4)
	require.NoError(t, err)
	require.Equal(t, "👨‍👩‍👧‍👦 请假", message)
	require.Equal(t, 4, count)
	_, _, err = NormalizeUserMessage("一二三四", 3)
	var runtimeErr *RuntimeError
	require.ErrorAs(t, err, &runtimeErr)
	require.Equal(t, "ai_message_too_long", runtimeErr.Code)
}

func TestRuntimeIdempotencyQuotaAndCitationCompletion(t *testing.T) {
	db := newRuntimeTestDB(t)
	seedPublishedKnowledgeSource(t, db, 9, 1)
	provider := &MockProvider{Response: ChatResponse{Content: "请按规定办理。[chunk:1]", InputTokens: 20, OutputTokens: 8}}
	retriever := fixedRetriever{result: RetrievalResult{Chunks: []RetrievedChunk{{
		ChunkID: 1, DocumentID: 9, Content: "请假需审批", Title: "学生手册", RRFScore: 0.05,
	}}}}
	runtime := newTestRuntime(t, db, provider, retriever)
	requestID := uuid.NewString()
	run, duplicate, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: requestID, Message: "怎么请假"})
	require.NoError(t, err)
	require.False(t, duplicate)
	waitRunState(t, db, run.ID, models.AIRunStateCompleted)

	duplicateRun, duplicate, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: requestID, Message: "不同文本"})
	require.NoError(t, err)
	require.True(t, duplicate)
	require.Equal(t, run.ID, duplicateRun.ID)

	for index := 0; index < 2; index++ {
		created, _, createErr := runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "请假规定"})
		require.NoError(t, createErr)
		waitRunState(t, db, created.ID, models.AIRunStateCompleted)
	}
	_, _, err = runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "还能问吗"})
	var runtimeErr *RuntimeError
	require.ErrorAs(t, err, &runtimeErr)
	require.Equal(t, "ai_quota_exceeded", runtimeErr.Code)

	_, err = runtime.GetRun(context.Background(), 8, run.ID)
	require.Error(t, err)
	var messages []models.AIConversationMessage
	require.NoError(t, db.Where("run_id = ?", run.ID).Order("created_at ASC").Find(&messages).Error)
	require.Len(t, messages, 2)
	require.Contains(t, messages[1].Content, "[1]")
	require.NotContains(t, messages[1].Content, "chunk:")
}

func TestRuntimeUnlimitedQuotaUsesVerifiedServerIdentity(t *testing.T) {
	db := newRuntimeTestDB(t)
	require.NoError(t, db.AutoMigrate(&models.User{}))
	verifiedAt := time.Now()
	unlimitedUser := models.User{
		ID: 101, StudentID: "2403130233", StudentVerifiedAt: &verifiedAt,
		PasswordHash: "test", AccountStatus: "active",
	}
	normalUser := models.User{
		ID: 102, StudentID: "2403130234", StudentVerifiedAt: &verifiedAt,
		PasswordHash: "test", AccountStatus: "active",
	}
	unverifiedUser := models.User{
		ID: 103, StudentID: "2403130999", PasswordHash: "test", AccountStatus: "active",
	}
	require.NoError(t, db.Create(&unlimitedUser).Error)
	require.NoError(t, db.Create(&normalUser).Error)
	require.NoError(t, db.Create(&unverifiedUser).Error)

	for _, userID := range []uint{unlimitedUser.ID, normalUser.ID, unverifiedUser.ID} {
		for index := 0; index < 3; index++ {
			require.NoError(t, db.Create(&models.AIQuotaEntry{
				UserID: userID, RunID: uuid.NewString(), Status: "consumed", CreatedAt: time.Now(),
			}).Error)
		}
	}

	runtime, err := NewRuntime(db, &MockProvider{}, fixedRetriever{}, NewEventBroker(), RuntimeConfig{
		ProviderName: "mock", Model: "mock", RequestTimeout: 5 * time.Second,
		MaxMessageChars: 20, HourlyMessageLimit: 3,
		UnlimitedStudentIDs:         []string{" 2403130233 ", "2403130233", "2403130999"},
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
		AuditHashSecret: "test-secret",
	})
	require.NoError(t, err)

	quota, err := runtime.Quota(context.Background(), unlimitedUser.ID)
	require.NoError(t, err)
	require.True(t, quota.Unlimited)
	require.Equal(t, 3, quota.Remaining)
	require.Nil(t, quota.ResetAt)

	created, _, err := runtime.CreateRun(context.Background(), unlimitedUser.ID, CreateRunRequest{
		ClientRequestID: uuid.NewString(), Message: "请假规定",
	})
	require.NoError(t, err)
	waitRunState(t, db, created.ID, models.AIRunStateFailed)

	normalQuota, err := runtime.Quota(context.Background(), normalUser.ID)
	require.NoError(t, err)
	require.False(t, normalQuota.Unlimited)
	require.Zero(t, normalQuota.Remaining)
	_, _, err = runtime.CreateRun(context.Background(), normalUser.ID, CreateRunRequest{
		ClientRequestID: uuid.NewString(), Message: "请假规定",
	})
	var runtimeErr *RuntimeError
	require.ErrorAs(t, err, &runtimeErr)
	require.Equal(t, "ai_quota_exceeded", runtimeErr.Code)

	unverifiedQuota, err := runtime.Quota(context.Background(), unverifiedUser.ID)
	require.NoError(t, err)
	require.False(t, unverifiedQuota.Unlimited)
	require.Zero(t, unverifiedQuota.Remaining)
}

func TestRuntimeRejectsLengthTruncatedProviderAnswer(t *testing.T) {
	db := newRuntimeTestDB(t)
	seedPublishedKnowledgeSource(t, db, 19, 91)
	provider := &staticEventProvider{
		requests: make(chan ProviderRequest, 1),
		events: []ProviderEvent{
			{Type: ProviderEventTextDelta, Text: "补考比例差异"},
			{Type: ProviderEventUsage, InputTokens: 120, OutputTokens: 4096},
			{Type: ProviderEventCompleted, FinishReason: "length"},
		},
	}
	retriever := fixedRetriever{result: RetrievalResult{Chunks: []RetrievedChunk{{
		ChunkID: 91, DocumentID: 19, Content: "补考成绩计算规则", Title: "学生手册", RRFScore: 0.05,
	}}}}
	runtime := newTestRuntime(t, db, provider, retriever)

	run, _, err := runtime.CreateRun(context.Background(), 21, CreateRunRequest{
		ClientRequestID: uuid.NewString(), Message: "补考怎么算",
	})
	require.NoError(t, err)
	request := <-provider.requests
	require.Equal(t, 4096, request.MaxTokens)

	failed := waitRunState(t, db, run.ID, models.AIRunStateFailed)
	require.Equal(t, ProviderErrorOutputLimit, failed.ErrorCode)
	require.Empty(t, failed.AnswerCheckpoint)

	var assistantMessages int64
	require.NoError(t, db.Model(&models.AIConversationMessage{}).
		Where("run_id = ? AND role = ?", run.ID, "assistant").Count(&assistantMessages).Error)
	require.Zero(t, assistantMessages)

	var completedEvents int64
	require.NoError(t, db.Model(&models.AIEvent{}).
		Where("run_id = ? AND type = ?", run.ID, "run.completed").Count(&completedEvents).Error)
	require.Zero(t, completedEvents)

	var usage models.AIUsageRecord
	require.NoError(t, db.First(&usage, "run_id = ?", run.ID).Error)
	require.Equal(t, 4096, usage.OutputTokens)
	require.Equal(t, ProviderErrorOutputLimit, usage.ErrorClass)
}

func TestCurrentPublishedChunksFailsClosedWhenKnowledgeTablesAreUnavailable(t *testing.T) {
	db := newRuntimeTestDB(t)
	runtime := &Runtime{db: db}

	chunks := runtime.currentPublishedChunks([]RetrievedChunk{{ChunkID: 1, DocumentID: 9}})

	require.Empty(t, chunks)
}

func TestCurrentPublishedChunksEnforcesDocumentAndVersionBoundary(t *testing.T) {
	db := newRuntimeTestDB(t)
	require.NoError(t, db.AutoMigrate(&models.AIKnowledgeDocument{}, &models.AIKnowledgeChunk{}))
	past := time.Now().Add(-time.Hour)
	documents := []models.AIKnowledgeDocument{
		{ID: 1, Title: "过期现行规定", SourceType: "official", DocumentType: "school_policy", Content: "正文一", ContentHash: "doc-1", Status: models.KnowledgeStatusPublished, EffectiveTo: &past, CreatedBy: 1},
		{ID: 2, Title: "正式历史规定", SourceType: "official_historical_compilation", DocumentType: "historical_school_policy", Content: "正文二", ContentHash: "doc-2", Status: models.KnowledgeStatusPublished, EffectiveTo: &past, CreatedBy: 1},
		{ID: 3, Title: "现行规定", SourceType: "official", DocumentType: "school_policy", Content: "正文三", ContentHash: "doc-3", Status: models.KnowledgeStatusPublished, CreatedBy: 1},
	}
	require.NoError(t, db.Create(&documents).Error)
	chunks := []models.AIKnowledgeChunk{
		{ID: 11, DocumentID: 1, ChunkIndex: 0, Content: "过期规则", ContentHash: "chunk-11", EmbeddingModelVersion: "fixture-v1"},
		{ID: 22, DocumentID: 2, ChunkIndex: 0, Content: "历史规则", ContentHash: "chunk-22", EmbeddingModelVersion: "fixture-v1"},
		{ID: 33, DocumentID: 3, ChunkIndex: 0, Content: "现行规则", ContentHash: "chunk-33", EmbeddingModelVersion: "fixture-v1"},
	}
	require.NoError(t, db.Create(&chunks).Error)
	runtime := &Runtime{db: db}

	validated := runtime.currentPublishedChunks([]RetrievedChunk{
		{ChunkID: 11, DocumentID: 1, CitationNumber: 1},
		{ChunkID: 22, DocumentID: 2, CitationNumber: 2},
		{ChunkID: 33, DocumentID: 99, CitationNumber: 3},
	})

	require.Len(t, validated, 1)
	require.Equal(t, uint64(22), validated[0].ChunkID)
	require.True(t, validated[0].Historical)
	require.Equal(t, models.KnowledgeStatusPublished, validated[0].Status)
	require.NotNil(t, validated[0].EffectiveTo)
	require.True(t, validated[0].EffectiveTo.Equal(past))
	require.Equal(t, 2, validated[0].CitationNumber)
}

func TestRuntimeReleasesQuotaAndBudgetBeforeGeneration(t *testing.T) {
	db := newRuntimeTestDB(t)
	runtime := newTestRuntime(t, db, &MockProvider{}, fixedRetriever{err: ErrRetrievalUnavailable})
	run, _, err := runtime.CreateRun(context.Background(), 11, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "请假规定"})
	require.NoError(t, err)
	waitRunState(t, db, run.ID, models.AIRunStateFailed)
	quota, err := runtime.Quota(context.Background(), 11)
	require.NoError(t, err)
	require.Equal(t, 3, quota.Remaining)
	var budget models.AIUserBudget
	require.NoError(t, db.First(&budget, "user_id = ?", 11).Error)
	require.Zero(t, budget.ReservedMicroYuan)
}

type blockingProvider struct{}

func (blockingProvider) Name() string { return "blocking" }
func (blockingProvider) Capabilities() ProviderCapabilities {
	return ProviderCapabilities{Streaming: true}
}
func (blockingProvider) Start(context.Context, ProviderRequest) (ProviderStream, error) {
	return blockingStream{}, nil
}

type blockingStream struct{}

func (blockingStream) Next(ctx context.Context) (ProviderEvent, error) {
	<-ctx.Done()
	return ProviderEvent{}, ctx.Err()
}
func (blockingStream) Close() error { return nil }

func TestRuntimeCancelStopsProviderAndDoesNotConsumePreGenerationQuota(t *testing.T) {
	db := newRuntimeTestDB(t)
	retriever := fixedRetriever{result: RetrievalResult{Chunks: []RetrievedChunk{{ChunkID: 1, DocumentID: 1, Content: "规则", Title: "手册"}}}}
	runtime := newTestRuntime(t, db, blockingProvider{}, retriever)
	run, _, err := runtime.CreateRun(context.Background(), 13, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "请假规定"})
	require.NoError(t, err)
	waitRunState(t, db, run.ID, models.AIRunStateGenerating)
	_, err = runtime.Cancel(context.Background(), 13, run.ID)
	require.NoError(t, err)
	waitRunState(t, db, run.ID, models.AIRunStateCancelled)
	require.Eventually(t, func() bool {
		quota, quotaErr := runtime.Quota(context.Background(), 13)
		return quotaErr == nil && quota.Remaining == 3
	}, time.Second, 10*time.Millisecond)
}

func TestProviderErrorClassPreservesKnownClassification(t *testing.T) {
	err := &ProviderError{Class: ProviderErrorRateLimited, Err: errors.New("remote detail")}
	require.Equal(t, ProviderErrorRateLimited, providerErrorClass(err))
	require.NotContains(t, err.Error(), "remote detail")
}
