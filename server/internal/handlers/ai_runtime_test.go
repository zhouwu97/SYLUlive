package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/ai"
	"shenliyuan/internal/models"
)

type emptyPolicyRetriever struct{}

func (emptyPolicyRetriever) Retrieve(context.Context, string) (ai.RetrievalResult, error) {
	return ai.RetrievalResult{}, nil
}

type handlerBlockingLangChain struct {
	cancelled chan struct{}
}

func (b *handlerBlockingLangChain) QueryPolicy(context.Context, ai.PolicyRAGInput) (ai.PolicyRAGResult, error) {
	return ai.PolicyRAGResult{}, nil
}

func (b *handlerBlockingLangChain) StreamPolicy(context.Context, ai.PolicyRAGInput) (ai.PolicyRAGEventStream, error) {
	return &handlerBlockingPolicyStream{cancelled: b.cancelled}, nil
}

type handlerBlockingPolicyStream struct {
	cancelled chan struct{}
	once      sync.Once
}

func (s *handlerBlockingPolicyStream) Next(ctx context.Context) (ai.PolicyRAGEvent, error) {
	<-ctx.Done()
	s.once.Do(func() { close(s.cancelled) })
	return ai.PolicyRAGEvent{}, ctx.Err()
}

func (s *handlerBlockingPolicyStream) Close() error { return nil }

func TestTerminalAIEvents(t *testing.T) {
	for _, eventType := range []string{"run.completed", "run.failed", "run.cancelled"} {
		if !isTerminalAIEvent(eventType) {
			t.Fatalf("%s should be terminal", eventType)
		}
	}
	if isTerminalAIEvent("answer.delta") {
		t.Fatal("answer.delta must not terminate SSE")
	}
}

func TestParseLastEventIDSupportsRunPrefix(t *testing.T) {
	if got := parseLastEventID("run-id:42"); got != 42 {
		t.Fatalf("parseLastEventID = %d, want 42", got)
	}
}

func TestAIEventsDisconnectKeepsRunAlive(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:%s?mode=memory&cache=shared", uuid.NewString())), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&models.AIConversation{}, &models.AIConversationMessage{}, &models.AIRun{},
		&models.AIEvent{}, &models.AIToolCall{}, &models.AIQuotaEntry{},
		&models.AIUserBudget{}, &models.AIBudgetReservation{}, &models.AIUsageRecord{},
	))
	blocking := &handlerBlockingLangChain{cancelled: make(chan struct{})}
	runtime, err := ai.NewRuntime(db, nil, nil, ai.NewEventBroker(), ai.RuntimeConfig{
		ProviderName: "langchain", Model: "python-policy-rag", RequestTimeout: 5 * time.Second,
		MaxMessageChars: 20, HourlyMessageLimit: 3,
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
		AuditHashSecret: "test-secret", LangChainRAGEnabled: true,
		LangChainRAGRolloutPercent: 100,
	}, ai.WithLangChainRAG(blocking))
	require.NoError(t, err)
	run, _, err := runtime.CreateRun(context.Background(), 27, ai.CreateRunRequest{
		ClientRequestID: uuid.NewString(), Message: "怎么请假",
	})
	require.NoError(t, err)
	require.Eventually(t, func() bool {
		current, getErr := runtime.GetRun(context.Background(), 27, run.ID)
		return getErr == nil && current.State == models.AIRunStateRetrieving
	}, time.Second, 10*time.Millisecond)

	router := gin.New()
	router.GET("/events/:id", func(c *gin.Context) {
		c.Set("user_id", uint(27))
		NewAIRuntimeHandler(db, runtime).Events(c)
	})
	server := httptest.NewServer(router)
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, server.URL+"/events/"+run.ID, nil)
	require.NoError(t, err)
	response, err := server.Client().Do(request)
	require.NoError(t, err)
	// 模拟客户端瞬间断开（Wi-Fi 切换、App 后台等）：订阅结束即可，
	// run 必须按自身生命周期继续推进，最终以非 cancelled 终态收尾。
	cancel()
	require.NoError(t, response.Body.Close())

	require.Eventually(t, func() bool {
		current, getErr := runtime.GetRun(context.Background(), 27, run.ID)
		return getErr == nil && isTerminalAIRunState(current.State) &&
			current.State != models.AIRunStateCancelled
	}, 10*time.Second, 50*time.Millisecond)
}

func TestCancelRunEndpointCancelsRun(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:%s?mode=memory&cache=shared", uuid.NewString())), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&models.AIConversation{}, &models.AIConversationMessage{}, &models.AIRun{},
		&models.AIEvent{}, &models.AIToolCall{}, &models.AIQuotaEntry{},
		&models.AIUserBudget{}, &models.AIBudgetReservation{}, &models.AIUsageRecord{},
	))
	blocking := &handlerBlockingLangChain{cancelled: make(chan struct{})}
	runtime, err := ai.NewRuntime(db, nil, nil, ai.NewEventBroker(), ai.RuntimeConfig{
		ProviderName: "langchain", Model: "python-policy-rag", RequestTimeout: 5 * time.Second,
		MaxMessageChars: 20, HourlyMessageLimit: 3,
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
		AuditHashSecret: "test-secret", LangChainRAGEnabled: true,
		LangChainRAGRolloutPercent: 100,
	}, ai.WithLangChainRAG(blocking))
	require.NoError(t, err)
	run, _, err := runtime.CreateRun(context.Background(), 27, ai.CreateRunRequest{
		ClientRequestID: uuid.NewString(), Message: "怎么请假",
	})
	require.NoError(t, err)
	require.Eventually(t, func() bool {
		current, getErr := runtime.GetRun(context.Background(), 27, run.ID)
		return getErr == nil && current.State == models.AIRunStateRetrieving
	}, time.Second, 10*time.Millisecond)

	router := gin.New()
	router.POST("/runs/:id/cancel", func(c *gin.Context) {
		c.Set("user_id", uint(27))
		NewAIRuntimeHandler(db, runtime).CancelRun(c)
	})
	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/runs/"+run.ID+"/cancel", nil))
	require.Equal(t, http.StatusOK, response.Code, response.Body.String())

	require.Eventually(t, func() bool {
		current, getErr := runtime.GetRun(context.Background(), 27, run.ID)
		return getErr == nil && current.State == models.AIRunStateCancelled
	}, time.Second, 10*time.Millisecond)
	select {
	case <-blocking.cancelled:
	default:
		t.Fatal("user cancel must propagate to the provider request context")
	}
}

func TestGetSourceChunkOnlyReturnsPublishedKnowledge(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:%s?mode=memory&cache=shared", uuid.NewString())), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.AIKnowledgeDocument{}, &models.AIKnowledgeChunk{}))

	document := models.AIKnowledgeDocument{
		Title: "学生手册", SourceType: "official", Content: "完整正文", ContentHash: "document-hash",
		Status: models.KnowledgeStatusPublished, CreatedBy: 1,
	}
	require.NoError(t, db.Create(&document).Error)
	chunk := models.AIKnowledgeChunk{
		DocumentID: document.ID, ChunkIndex: 0, Content: "补考规则正文", ContentHash: "chunk-hash",
		SearchTokens: "补考", Embedding: "[]", SourceLocator: "chunk:1", EmbeddingModelVersion: "test",
	}
	require.NoError(t, db.Create(&chunk).Error)

	router := gin.New()
	router.GET("/sources/chunks/:chunk_id", NewAIRuntimeHandler(db, nil).GetSourceChunk)
	path := fmt.Sprintf("/sources/chunks/%d", chunk.ID)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
	require.Equal(t, http.StatusOK, response.Code, response.Body.String())
	require.Contains(t, response.Body.String(), `"content":"补考规则正文"`)
	require.Equal(t, "private, max-age=300", response.Header().Get("Cache-Control"))

	require.NoError(t, db.Model(&document).Update("status", models.KnowledgeStatusRevoked).Error)
	response = httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
	require.Equal(t, http.StatusNotFound, response.Code, response.Body.String())
}

func TestGetRunSourcesOnlyReturnsOwnedPersistedSources(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:%s?mode=memory&cache=shared", uuid.NewString())), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.AIRun{}, &models.AIEvent{}))

	userID := uint(41)
	runID := uuid.NewString()
	require.NoError(t, db.Create(&models.AIRun{
		ID: runID, UserID: userID, ConversationID: uuid.NewString(), ClientRequestID: uuid.NewString(),
		State: models.AIRunStateCompleted, Provider: "mock", Model: "mock", MessageHash: "hash",
		MessageLength: 1, ExpiresAt: time.Now().Add(time.Hour),
	}).Error)
	payload, err := json.Marshal(map[string]any{
		"sources": []map[string]any{{
			"primary_chunk_id": 18,
			"document_id":      3,
			"title":            "学生手册",
			"citation_numbers": []int{1},
		}},
	})
	require.NoError(t, err)
	require.NoError(t, db.Create(&models.AIEvent{
		RunID: runID, Seq: 1, Type: "sources.ready", Payload: payload, CreatedAt: time.Now(),
	}).Error)

	router := gin.New()
	router.GET("/runs/:id/sources", func(c *gin.Context) {
		c.Set("user_id", userID)
		NewAIRuntimeHandler(db, nil).GetRunSources(c)
	})

	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/runs/"+runID+"/sources", nil))
	require.Equal(t, http.StatusOK, response.Code, response.Body.String())
	require.Contains(t, response.Body.String(), `"primary_chunk_id":18`)
	require.Contains(t, response.Body.String(), `"title":"学生手册"`)

	response = httptest.NewRecorder()
	userID = 99
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/runs/"+runID+"/sources", nil))
	require.Equal(t, http.StatusNotFound, response.Code, response.Body.String())
}

func TestDeleteConversationRetainsConsumedQuotaLedger(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:%s?mode=memory&cache=shared", uuid.NewString())), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&models.AIConversation{}, &models.AIConversationMessage{}, &models.AIRun{},
		&models.AIEvent{}, &models.AIToolCall{}, &models.AIQuotaEntry{},
		&models.AIUserBudget{}, &models.AIBudgetReservation{}, &models.AIUsageRecord{},
	))
	runtime, err := ai.NewRuntime(db, &ai.MockProvider{}, emptyPolicyRetriever{}, ai.NewEventBroker(), ai.RuntimeConfig{
		ProviderName: "mock", Model: "mock", RequestTimeout: 5 * time.Second,
		MaxToolSteps:    3,
		MaxMessageChars: 20, HourlyMessageLimit: 3,
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
		AuditHashSecret: "test-secret",
	})
	require.NoError(t, err)

	userID := uint(17)
	conversationID := uuid.NewString()
	runID := uuid.NewString()
	now := time.Now()
	require.NoError(t, db.Create(&models.AIConversation{ID: conversationID, UserID: userID}).Error)
	require.NoError(t, db.Create(&models.AIRun{
		ID: runID, UserID: userID, ConversationID: conversationID, ClientRequestID: uuid.NewString(),
		State: models.AIRunStateCompleted, Provider: "mock", Model: "mock", MessageHash: "hash",
		MessageLength: 1, ExpiresAt: now.Add(time.Hour), CompletedAt: &now,
	}).Error)
	require.NoError(t, db.Create(&models.AIQuotaEntry{
		UserID: userID, RunID: runID, Status: "consumed", CreatedAt: now,
	}).Error)

	router := gin.New()
	router.DELETE("/conversations/:id", func(c *gin.Context) {
		c.Set("user_id", userID)
		NewAIRuntimeHandler(db, runtime).DeleteConversation(c)
	})
	request := httptest.NewRequest(http.MethodDelete, "/conversations/"+conversationID, nil)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	require.Equal(t, http.StatusNoContent, response.Code, response.Body.String())

	var quota models.AIQuotaEntry
	require.NoError(t, db.Where("user_id = ?", userID).First(&quota).Error)
	require.Equal(t, "consumed", quota.Status)
	require.NotEqual(t, runID, quota.RunID)
	quotaStatus, err := runtime.Quota(context.Background(), userID)
	require.NoError(t, err)
	require.Equal(t, 2, quotaStatus.Remaining)
	var runCount, conversationCount int64
	require.NoError(t, db.Model(&models.AIRun{}).Where("id = ?", runID).Count(&runCount).Error)
	require.NoError(t, db.Model(&models.AIConversation{}).Where("id = ?", conversationID).Count(&conversationCount).Error)
	require.Zero(t, runCount)
	require.Zero(t, conversationCount)
}

func TestListConversationsWithPreview(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:%s?mode=memory&cache=shared", uuid.NewString())), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&models.AIConversation{}, &models.AIConversationMessage{},
	))
	runtime, err := ai.NewRuntime(db, &ai.MockProvider{}, emptyPolicyRetriever{}, ai.NewEventBroker(), ai.RuntimeConfig{
		ProviderName: "mock", Model: "mock", RequestTimeout: 5 * time.Second,
		MaxToolSteps:    3,
		MaxMessageChars: 20, HourlyMessageLimit: 3,
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
		AuditHashSecret: "test-secret",
	})
	require.NoError(t, err)

	userID := uint(18)
	c1 := uuid.NewString()
	require.NoError(t, db.Create(&models.AIConversation{ID: c1, UserID: userID, Title: "C1"}).Error)
	require.NoError(t, db.Create(&models.AIConversationMessage{
		ID: "1", ConversationID: c1, Role: "user", Content: "Hello C1", CreatedAt: time.Now(),
	}).Error)

	c2 := uuid.NewString()
	require.NoError(t, db.Create(&models.AIConversation{ID: c2, UserID: userID, Title: "C2", UpdatedAt: time.Now().Add(time.Second)}).Error)
	require.NoError(t, db.Create(&models.AIConversationMessage{
		ID: "2", ConversationID: c2, Role: "user", Content: "Hello C2", CreatedAt: time.Now(),
	}).Error)
	require.NoError(t, db.Create(&models.AIConversationMessage{
		ID: "3", ConversationID: c2, Role: "assistant", Content: "Response C2", CreatedAt: time.Now().Add(time.Second),
	}).Error)

	router := gin.New()
	router.GET("/conversations", func(c *gin.Context) {
		c.Set("user_id", userID)
		NewAIRuntimeHandler(db, runtime).ListConversations(c)
	})

	request := httptest.NewRequest(http.MethodGet, "/conversations", nil)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	require.Equal(t, http.StatusOK, response.Code)

	body := response.Body.String()
	require.Contains(t, body, `"last_message_preview":"Response C2"`)
	require.Contains(t, body, `"last_message_preview":"Hello C1"`)
}
