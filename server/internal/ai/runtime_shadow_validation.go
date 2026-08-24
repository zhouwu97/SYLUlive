package ai

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

func (r *Runtime) ownedRun(ctx context.Context, userID uint, runID string) (models.AIRun, error) {
	if userID == 0 {
		return models.AIRun{}, &RuntimeError{Code: "authentication_required", Message: "需要登录"}
	}
	if _, err := uuid.Parse(strings.TrimSpace(runID)); err != nil {
		return models.AIRun{}, &RuntimeError{Code: "invalid_run_id", Message: "Run ID 无效"}
	}
	var run models.AIRun
	if err := r.db.WithContext(ctx).Where("id = ? AND user_id = ?", runID, userID).First(&run).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return models.AIRun{}, &RuntimeError{Code: "ai_run_not_found", Message: "Run 不存在"}
		}
		return models.AIRun{}, err
	}
	return run, nil
}

// RecordUserSignal 记录真实用户反馈的结构化信号。可选说明只保留摘要，
// 不会把用户正文复制到 Trace 或回归样本候选中。
func (r *Runtime) RecordUserSignal(ctx context.Context, userID uint, runID string, signal AgentUserSignal, details ...string) error {
	run, err := r.ownedRun(ctx, userID, runID)
	if err != nil {
		return err
	}
	if !signal.Valid() {
		return &RuntimeError{Code: "invalid_agent_user_signal", Message: "反馈信号无效"}
	}
	payload := map[string]interface{}{
		"trace_id": string(run.ID),
		"signal":   signal,
	}
	if detail := sanitizedDetail(details); detail != "" {
		payload["detail_hash"] = detailHash(detail)
		payload["detail_length"] = utf8.RuneCountInString(detail)
	}
	if signal == UserSignalFirstActivity || signal == UserSignalFirstUsefulAnswer {
		startedAt := run.StartedAt
		if startedAt == nil {
			startedAt = &run.CreatedAt
		}
		elapsed := time.Since(*startedAt).Milliseconds()
		if elapsed < 0 {
			elapsed = 0
		}
		if signal == UserSignalFirstActivity {
			payload["time_to_first_activity_ms"] = elapsed
		} else {
			payload["time_to_useful_answer_ms"] = elapsed
		}
	}
	_, err = r.appendEvent(ctx, run.ID, string(signal), payload, true)
	return err
}

// ClassifyFailure 将已发生的线上故障转成脱敏回归候选。
// case_id 稳定绑定 trace 与失败类别，离线导出时再由人工补齐可复现输入。
func (r *Runtime) ClassifyFailure(ctx context.Context, userID uint, runID string, reason AgentFailureReason, details ...string) (RegressionScenarioCandidate, error) {
	run, err := r.ownedRun(ctx, userID, runID)
	if err != nil {
		return RegressionScenarioCandidate{}, err
	}
	if !reason.Valid() {
		return RegressionScenarioCandidate{}, &RuntimeError{Code: "invalid_agent_failure_reason", Message: "失败分类无效"}
	}
	candidate := RegressionScenarioCandidate{
		CaseID:        "real_trace." + run.ID + "." + string(reason),
		SourceTraceID: run.ID,
		FailureReason: reason,
		Candidate:     true,
		Deterministic: false,
	}
	payload := map[string]interface{}{"trace_id": run.ID, "failure_reason": reason}
	if detail := sanitizedDetail(details); detail != "" {
		payload["detail_hash"] = detailHash(detail)
		payload["detail_length"] = utf8.RuneCountInString(detail)
	}
	if _, err := r.appendEvent(ctx, run.ID, "run.failure_classified", payload, true); err != nil {
		return RegressionScenarioCandidate{}, err
	}
	if _, err := r.appendEvent(ctx, run.ID, "regression.scenario_candidate", candidate.Payload(), true); err != nil {
		return RegressionScenarioCandidate{}, err
	}
	return candidate, nil
}

func sanitizedDetail(details []string) string {
	if len(details) == 0 {
		return ""
	}
	value := strings.TrimSpace(details[0])
	if utf8.RuneCountInString(value) > 200 {
		value = string([]rune(value)[:200])
	}
	return value
}

func detailHash(value string) string {
	digest := sha256.Sum256([]byte(value))
	return hex.EncodeToString(digest[:])
}

// TraceMetrics 从已持久化的脱敏事件派生真实用户指标，不读取会话正文。
func (r *Runtime) TraceMetrics(ctx context.Context, userID uint, runID string) (AgentTraceMetrics, error) {
	if _, err := r.ownedRun(ctx, userID, runID); err != nil {
		return AgentTraceMetrics{}, err
	}
	var events []models.AIEvent
	if err := r.db.WithContext(ctx).Where("run_id = ?", runID).Order("seq ASC").Find(&events).Error; err != nil {
		return AgentTraceMetrics{}, err
	}
	var metrics AgentTraceMetrics
	for _, event := range events {
		metrics.Observe(event.Type, event.Payload)
	}
	return metrics, nil
}
