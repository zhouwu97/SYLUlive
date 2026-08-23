package handlers

import (
	"fmt"
	"net/http"
	"sort"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type AdminAIHandler struct{ db *gorm.DB }

func NewAdminAIHandler(db *gorm.DB) *AdminAIHandler { return &AdminAIHandler{db: db} }

// GetMetrics 只返回聚合指标，不返回 prompt、用户正文、user_hash 或 API Key。
func (h *AdminAIHandler) GetMetrics(c *gin.Context) {
	days := 7
	if value := c.Query("days"); value != "" {
		if _, err := fmt.Sscanf(value, "%d", &days); err != nil || days < 1 || days > 31 {
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_days"})
			return
		}
	}
	from := time.Now().UTC().Add(-time.Duration(days) * 24 * time.Hour)
	var records []models.AIUsageRecord
	if err := h.db.WithContext(c.Request.Context()).Where("created_at >= ?", from).Find(&records).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ai_metrics_unavailable"})
		return
	}
	totalTokens, totalCost, successCount := 0, int64(0), 0
	latencies := make([]int64, 0, len(records))
	byProvider := map[string]map[string]interface{}{}
	byPurpose := map[string]int{}
	byError := map[string]int{}
	for _, record := range records {
		totalTokens += record.InputTokens + record.OutputTokens
		totalCost += record.CostMicroYuan
		if record.ErrorClass == "" {
			successCount++
		} else {
			byError[record.ErrorClass]++
		}
		if record.LatencyMilliseconds >= 0 {
			latencies = append(latencies, record.LatencyMilliseconds)
		}
		key := record.Provider
		item := byProvider[key]
		if item == nil {
			item = map[string]interface{}{"provider": key, "requests": 0, "tokens": 0, "cost_micro_yuan": int64(0)}
			byProvider[key] = item
		}
		item["requests"] = item["requests"].(int) + 1
		item["tokens"] = item["tokens"].(int) + record.InputTokens + record.OutputTokens
		item["cost_micro_yuan"] = item["cost_micro_yuan"].(int64) + record.CostMicroYuan
		purpose := record.Purpose
		if purpose == "" {
			purpose = "campus_agent"
		}
		byPurpose[purpose]++
	}
	providers := make([]map[string]interface{}, 0, len(byProvider))
	for _, value := range byProvider {
		providers = append(providers, value)
	}
	sort.Slice(providers, func(i, j int) bool { return providers[i]["provider"].(string) < providers[j]["provider"].(string) })
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	percentile := func(p float64) int64 {
		if len(latencies) == 0 {
			return 0
		}
		index := int(float64(len(latencies)-1)*p + 0.5)
		return latencies[index]
	}
	var toolCalls, deviceJobs int64
	_ = h.db.WithContext(c.Request.Context()).Model(&models.AIToolCall{}).Where("created_at >= ?", from).Count(&toolCalls).Error
	_ = h.db.WithContext(c.Request.Context()).Model(&models.DeviceToolJob{}).Where("created_at >= ?", from).Count(&deviceJobs).Error
	c.JSON(http.StatusOK, gin.H{"from": from, "to": time.Now().UTC(), "days": days, "requests": len(records), "success_count": successCount, "success_rate": rate(successCount, len(records)), "input_output_tokens": totalTokens, "cost_micro_yuan": totalCost, "latency_ms": gin.H{"p50": percentile(0.5), "p95": percentile(0.95)}, "by_provider": providers, "by_purpose": byPurpose, "errors": byError, "mcp_tool_calls": toolCalls, "device_jobs": deviceJobs})
}

func rate(success, total int) float64 {
	if total == 0 {
		return 0
	}
	return float64(success) / float64(total)
}
