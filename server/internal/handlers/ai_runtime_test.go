package handlers

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
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
		MaxMessageChars: 100, HourlyMessageLimit: 3,
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
	remaining, _, err := runtime.Quota(context.Background(), userID)
	require.NoError(t, err)
	require.Equal(t, 2, remaining)
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
		MaxMessageChars: 100, HourlyMessageLimit: 3,
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
