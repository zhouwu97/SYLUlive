package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
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

type communityRecordingProvider struct {
	ai.MockProvider
	requests chan ai.ProviderRequest
}

func (provider *communityRecordingProvider) Start(ctx context.Context, request ai.ProviderRequest) (ai.ProviderStream, error) {
	provider.requests <- request
	return provider.MockProvider.Start(ctx, request)
}

// 使用真实 HTTP Handler、Runtime、工具审计与临时数据库；模型固定响应，不调用外网。
func TestCommunityReadRunHTTPFlow(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = sqlDB.Close() })
	require.NoError(t, db.AutoMigrate(
		&models.Post{}, &models.Reply{}, &models.AIConversation{}, &models.AIConversationMessage{},
		&models.AIRun{}, &models.AIEvent{}, &models.AIToolCall{}, &models.AIQuotaEntry{},
		&models.AIUserBudget{}, &models.AIBudgetReservation{}, &models.AIUsageRecord{},
	))
	post := models.Post{ID: 123, BoardID: models.BoardShuitie, AuthorID: 1, Title: "食堂口味讨论", Content: "合成讨论：这道菜偏咸", Contact: "not-for-model-contact", ViewCount: 13}
	require.NoError(t, db.Create(&post).Error)
	require.NoError(t, db.Create(&models.Reply{PostID: post.ID, AuthorID: 2, Content: "合成评论：我觉得刚好"}).Error)
	stickers := make([]ai.CommunitySticker, 0)
	for _, item := range ListBuiltinStickers() {
		stickers = append(stickers, ai.CommunitySticker{ID: item.ID, Label: item.Label})
	}
	registry, err := ai.NewToolRegistry(db, ai.NewCampusMCPTools(db, nil, nil, ai.WithCampusCommunityReadTools(stickers))...)
	require.NoError(t, err)
	provider := &communityRecordingProvider{MockProvider: ai.MockProvider{Response: ai.ChatResponse{Content: "大家对咸淡的感受不同。", InputTokens: 10, OutputTokens: 10}}, requests: make(chan ai.ProviderRequest, 8)}
	runtime, err := ai.NewRuntime(db, provider, emptyPolicyRetriever{}, ai.NewEventBroker(), ai.RuntimeConfig{
		ProviderName: "mock", Model: "mock", RequestTimeout: 5 * time.Second,
		MaxToolSteps: 3, MaxMessageChars: 120, HourlyMessageLimit: 3,
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
		AuditHashSecret: "synthetic-community-test",
	}, ai.WithToolRegistry(registry))
	require.NoError(t, err)
	router := gin.New()
	router.POST("/api/ai/runs", func(c *gin.Context) {
		// 鉴权中间件有独立回归，此处模拟其已经验证的身份。
		c.Set("user_id", uint(7))
		NewAIRuntimeHandler(db, runtime).CreateRun(c)
	})
	payload, err := json.Marshal(map[string]interface{}{
		"client_request_id": uuid.NewString(), "message": "请概括这条帖子和评论的观点",
		"context": ai.AgentContextEnvelope{Entrypoint: "post_detail", ContextRefs: []ai.AgentContextRef{{Type: "post", ID: "123"}}},
	})
	require.NoError(t, err)
	postRun := func(body []byte) *httptest.ResponseRecorder {
		response := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodPost, "/api/ai/runs", strings.NewReader(string(body)))
		request.Header.Set("Content-Type", "application/json")
		router.ServeHTTP(response, request)
		return response
	}
	response := postRun(payload)
	require.Equal(t, http.StatusAccepted, response.Code, response.Body.String())
	var accepted struct {
		Run models.AIRun `json:"run"`
	}
	require.NoError(t, json.Unmarshal(response.Body.Bytes(), &accepted))
	select {
	case request := <-provider.requests:
		raw, err := json.Marshal(request.Messages)
		require.NoError(t, err)
		require.Contains(t, string(raw), "合成讨论：这道菜偏咸")
		require.Contains(t, string(raw), "合成评论：我觉得刚好")
		require.Contains(t, string(raw), "untrusted_tool_data")
		require.NotContains(t, string(raw), "not-for-model-contact")
	case <-time.After(6 * time.Second):
		t.Fatal("Runtime 未向固定模型提供页面数据")
	}
	require.Eventually(t, func() bool {
		run, err := runtime.GetRun(context.Background(), 7, accepted.Run.ID)
		return err == nil && run.State == models.AIRunStateCompleted
	}, 6*time.Second, 10*time.Millisecond)
	require.Equal(t, http.StatusOK, postRun(payload).Code)
	select {
	case <-provider.requests:
		t.Fatal("重复 HTTP 请求再次调用了模型")
	default:
	}
	var stored models.Post
	require.NoError(t, db.First(&stored, post.ID).Error)
	require.Equal(t, 13, stored.ViewCount)
	var replies, runs int64
	require.NoError(t, db.Model(&models.Reply{}).Count(&replies).Error)
	require.EqualValues(t, 1, replies)
	require.NoError(t, db.Model(&models.Post{}).Where("id = ?", post.ID).Update("status", models.PostStatusModeratedHidden).Error)
	response = postRun(payload)
	require.Equal(t, http.StatusUnprocessableEntity, response.Code, response.Body.String())
	require.Contains(t, response.Body.String(), "invalid_agent_context")
	require.NoError(t, db.Model(&models.AIRun{}).Count(&runs).Error)
	require.EqualValues(t, 1, runs)
}
