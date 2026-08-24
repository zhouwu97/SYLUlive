package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/ai"
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

// GrayDashboardMetrics 是 Real User Gray v1 的最小运营指标，不携带正文或用户标识。
type GrayDashboardMetrics struct {
	Runs                          int     `json:"runs"`
	ActiveUsers                   int     `json:"active_users"`
	SuccessRate                   float64 `json:"success_rate"`
	UserCorrectionRate            float64 `json:"user_correction_rate"`
	PossibleCorrectionRate        float64 `json:"possible_correction_rate"`
	DegradedRunRate               float64 `json:"degraded_run_rate"`
	ActionVerificationFailureRate float64 `json:"action_verification_failure_rate"`
	FastNormalUpgradeRate         float64 `json:"fast_normal_upgrade_rate"`
	P95TimeToUsefulAnswerMs       int64   `json:"p95_time_to_useful_answer_ms"`
	PermissionBypasses            int     `json:"permission_bypasses"`
	FalseActionSuccesses          int     `json:"false_action_successes"`
	CrossUserContaminations       int     `json:"cross_user_contaminations"`
	Abandonments                  int     `json:"abandonments"`
	Rephrases                     int     `json:"rephrases"`
	UsefulAnswers                 int     `json:"useful_answers"`
}

type GrayAlert struct {
	Severity  string  `json:"severity"`
	Metric    string  `json:"metric"`
	Value     float64 `json:"value"`
	Threshold float64 `json:"threshold"`
	Action    string  `json:"action"`
}

type GrayThresholds struct {
	ActionVerificationFailureRate float64 `json:"action_verification_failure_rate"`
	DegradedRunRate               float64 `json:"degraded_run_rate"`
	FastNormalUpgradeRate         float64 `json:"fast_normal_upgrade_rate"`
	UserCorrectionRate            float64 `json:"user_correction_rate"`
	P95TimeToUsefulAnswerMs       int64   `json:"p95_time_to_useful_answer_ms"`
}

func defaultGrayThresholds() GrayThresholds {
	return GrayThresholds{
		ActionVerificationFailureRate: 0.05,
		DegradedRunRate:               0.20,
		FastNormalUpgradeRate:         0.40,
		UserCorrectionRate:            0.15,
		P95TimeToUsefulAnswerMs:       8000,
	}
}

// EvaluateGrayAlerts 将红线与 P1 指标转换为可执行的 kill-switch 建议。
func EvaluateGrayAlerts(metrics GrayDashboardMetrics, thresholds GrayThresholds) []GrayAlert {
	alerts := make([]GrayAlert, 0, 8)
	if metrics.PermissionBypasses > 0 {
		alerts = append(alerts, GrayAlert{"P0", "permission_bypasses", float64(metrics.PermissionBypasses), 0, "disable_actions_and_agent"})
	}
	if metrics.FalseActionSuccesses > 0 {
		alerts = append(alerts, GrayAlert{"P0", "false_action_successes", float64(metrics.FalseActionSuccesses), 0, "disable_actions"})
	}
	if metrics.CrossUserContaminations > 0 {
		alerts = append(alerts, GrayAlert{"P0", "cross_user_contaminations", float64(metrics.CrossUserContaminations), 0, "disable_agent"})
	}
	for _, item := range []GrayAlert{
		{"P1", "action_verification_failure_rate", metrics.ActionVerificationFailureRate, thresholds.ActionVerificationFailureRate, "disable_actions"},
		{"P1", "degraded_run_rate", metrics.DegradedRunRate, thresholds.DegradedRunRate, "pause_affected_capability"},
		{"P1", "fast_normal_upgrade_rate", metrics.FastNormalUpgradeRate, thresholds.FastNormalUpgradeRate, "pause_fast_mode_upgrade"},
		{"P1", "user_correction_rate", metrics.UserCorrectionRate, thresholds.UserCorrectionRate, "pause_rollout_and_review"},
		{"P1", "p95_time_to_useful_answer_ms", float64(metrics.P95TimeToUsefulAnswerMs), float64(thresholds.P95TimeToUsefulAnswerMs), "pause_rollout_and_review"},
	} {
		if item.Value > item.Threshold && item.Threshold > 0 {
			alerts = append(alerts, item)
		}
	}
	return alerts
}

func (h *AdminAIHandler) GetGrayDashboard(c *gin.Context) {
	days := 7
	if value := c.Query("days"); value != "" {
		if _, err := fmt.Sscanf(value, "%d", &days); err != nil || days < 1 || days > 31 {
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_days"})
			return
		}
	}
	now := time.Now().UTC()
	from := now.Add(-time.Duration(days) * 24 * time.Hour)
	var runs []models.AIRun
	if err := h.db.WithContext(c.Request.Context()).Where("created_at >= ?", from).Find(&runs).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ai_gray_dashboard_unavailable"})
		return
	}
	metrics := GrayDashboardMetrics{Runs: len(runs)}
	users := map[uint]struct{}{}
	latencies := make([]int64, 0, len(runs))
	for _, run := range runs {
		users[run.UserID] = struct{}{}
		if run.State == models.AIRunStateCompleted {
			metrics.SuccessRate++
		}
	}
	metrics.ActiveUsers = len(users)
	if metrics.Runs > 0 {
		metrics.SuccessRate /= float64(metrics.Runs)
	}
	ids := make([]string, 0, len(runs))
	for _, run := range runs {
		ids = append(ids, run.ID)
	}
	var events []models.AIEvent
	if len(ids) > 0 {
		if err := h.db.WithContext(c.Request.Context()).Where("run_id IN ?", ids).Order("seq ASC").Find(&events).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"code": "ai_gray_dashboard_unavailable"})
			return
		}
	}
	byRun := make(map[string]ai.AgentTraceMetrics, len(ids))
	for _, event := range events {
		trace := byRun[event.RunID]
		trace.Observe(event.Type, event.Payload)
		byRun[event.RunID] = trace
		var raw map[string]interface{}
		if json.Unmarshal(event.Payload, &raw) == nil {
			switch event.Type {
			case "permission.bypass":
				metrics.PermissionBypasses++
			case "action.false_success":
				metrics.FalseActionSuccesses++
			case "cross_user.contamination":
				metrics.CrossUserContaminations++
			}
		}
	}
	correction, possible, degraded, verify, upgrades, upgradeRuns := 0, 0, 0, 0, 0, 0
	for _, trace := range byRun {
		correction += trace.UserCorrections
		possible += trace.PossibleUserCorrections
		if trace.DegradedRuns > 0 {
			degraded++
		}
		verify += trace.ActionVerificationFailures
		upgrades += trace.FastEscalations
		if trace.FastEscalations > 0 {
			upgradeRuns++
		}
		if trace.TimeToUsefulAnswerMs > 0 {
			latencies = append(latencies, trace.TimeToUsefulAnswerMs)
		}
		metrics.Abandonments += trace.Abandonments
		metrics.Rephrases += trace.Rephrases
		metrics.UsefulAnswers += trace.UsefulAnswers
	}
	denominator := len(runs)
	metrics.UserCorrectionRate = rate(correction, denominator)
	metrics.PossibleCorrectionRate = rate(possible, denominator)
	metrics.DegradedRunRate = rate(degraded, denominator)
	metrics.ActionVerificationFailureRate = rate(verify, denominator)
	metrics.FastNormalUpgradeRate = rate(upgrades, maxInt(denominator, upgradeRuns))
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	if len(latencies) > 0 {
		metrics.P95TimeToUsefulAnswerMs = latencies[int(float64(len(latencies)-1)*0.95+0.5)]
	}
	thresholds := defaultGrayThresholds()
	c.JSON(http.StatusOK, gin.H{
		"from": from, "to": now, "days": days, "metrics": metrics,
		"thresholds": thresholds, "alerts": EvaluateGrayAlerts(metrics, thresholds),
		"kill_switch_path": []string{"AI_AGENT_ACTIONS_ENABLED=false", "AI_AGENT_PERSONAL_DATA_ENABLED=false", "AI_AGENT_ENABLED=false"},
	})
}

func maxInt(value, fallback int) int {
	if value > 0 {
		return value
	}
	return fallback
}
