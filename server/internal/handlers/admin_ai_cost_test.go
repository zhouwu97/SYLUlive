package handlers

import (
	"encoding/json"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
)

func TestAdminMetricsSeparatesUnknownModelsAndKeepsLegacyCurrency(t *testing.T) {
	db := openAccountIdentityTestDB(t)
	require.NoError(t, db.AutoMigrate(&models.AIUsageRecord{}, &models.AIToolCall{}, &models.DeviceToolJob{}))
	require.NoError(t, db.Create(&[]models.AIUsageRecord{
		{RunID: "terra", Provider: "openai-compatible", Model: "gpt-5.6-terra", InputTokens: 3476, OutputTokens: 759, CostMicroYuan: 26048},
		{RunID: "luna", Provider: "openai-compatible", Model: "gpt-5.6-luna", InputTokens: 3814, OutputTokens: 115, CostMicroYuan: 17096},
		{RunID: "legacy", Provider: "openai-compatible", Model: "gpt-5.4-mini", InputTokens: 10, CostMicroYuan: 40},
	}).Error)
	w := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(w)
	ctx.Request = httptest.NewRequest("GET", "/admin/ai/metrics?days=7", nil)
	NewAdminAIHandler(db).GetMetrics(ctx)
	require.Equal(t, 200, w.Code)
	var body map[string]interface{}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &body))
	require.Equal(t, "USD", body["cost_currency"])
	require.Equal(t, float64(3_392_160), body["cost_nano_usd"])
	require.Equal(t, float64(43184), body["cost_micro_yuan"])
	require.Equal(t, float64(2), body["priced_requests"])
	require.Equal(t, float64(1), body["unpriced_requests"])
	require.Len(t, body["by_model"], 3)
	provider := body["by_provider"].([]interface{})[0].(map[string]interface{})
	require.Equal(t, body["cost_nano_usd"], provider["cost_nano_usd"])
	require.Equal(t, body["unpriced_requests"], provider["unpriced_requests"])
	for _, key := range []string{"user_hash", "model_usage", "run_id"} {
		require.NotContains(t, w.Body.String(), key)
	}
}
