package ai

import (
	"context"
	"time"

	"shenliyuan/internal/models"
)

var shadowObservabilityTypes = []string{
	"shadow.started", "shadow.completed",
}

var failureObservabilityTypes = []string{
	"user.correction", "possible_user_correction", "clarification.unnecessary",
	"run.abandoned", "run.rephrased", "answer.useful", "run.first_activity",
	"answer.first_useful", "run.failure_classified", "regression.scenario_candidate",
}

type ObservabilityDeletion struct {
	RunCount   int64 `json:"run_count"`
	EventCount int64 `json:"event_count"`
}

// DeleteRunObservability 删除指定用户指定 Run 的观测事件，不删除回答正文、Run 状态或工具结果。
func (r *Runtime) DeleteRunObservability(ctx context.Context, userID uint, runID string) (ObservabilityDeletion, error) {
	if _, err := r.ownedRun(ctx, userID, runID); err != nil {
		return ObservabilityDeletion{}, err
	}
	return r.deleteObservabilityForRuns(ctx, []string{runID})
}

// DeleteUserObservability 删除指定用户所有 Run 的观测事件，保留用户主动保存的会话内容。
func (r *Runtime) DeleteUserObservability(ctx context.Context, userID uint) (ObservabilityDeletion, error) {
	if userID == 0 {
		return ObservabilityDeletion{}, &RuntimeError{Code: "authentication_required", Message: "需要登录"}
	}
	var runs []models.AIRun
	if err := r.db.WithContext(ctx).Where("user_id = ?", userID).Find(&runs).Error; err != nil {
		return ObservabilityDeletion{}, err
	}
	ids := make([]string, 0, len(runs))
	for _, run := range runs {
		ids = append(ids, run.ID)
	}
	return r.deleteObservabilityForRuns(ctx, ids)
}

func (r *Runtime) deleteObservabilityForRuns(ctx context.Context, runIDs []string) (ObservabilityDeletion, error) {
	if len(runIDs) == 0 {
		return ObservabilityDeletion{}, nil
	}
	result := r.db.WithContext(ctx).
		Where("run_id IN ? AND type IN ?", runIDs, append(shadowObservabilityTypes, failureObservabilityTypes...)).
		Delete(&models.AIEvent{})
	if result.Error != nil {
		return ObservabilityDeletion{}, result.Error
	}
	return ObservabilityDeletion{RunCount: int64(len(runIDs)), EventCount: result.RowsAffected}, nil
}

// ReclaimObservabilityData 是可由部署任务定期调用的保留策略入口。
// 只清理 Shadow 和用户反馈/失败分类事件，核心事件仍用于 Run 恢复。
func (r *Runtime) ReclaimObservabilityData(ctx context.Context, now time.Time) (int64, error) {
	shadowRetention := r.config.ShadowTraceRetention
	failureRetention := r.config.FailureTraceRetention
	if shadowRetention <= 0 {
		shadowRetention = 14 * 24 * time.Hour
	}
	if failureRetention <= 0 {
		failureRetention = 60 * 24 * time.Hour
	}
	var total int64
	for _, item := range []struct {
		types  []string
		before time.Time
	}{
		{shadowObservabilityTypes, now.Add(-shadowRetention)},
		{failureObservabilityTypes, now.Add(-failureRetention)},
	} {
		result := r.db.WithContext(ctx).
			Where("type IN ? AND created_at < ?", item.types, item.before).
			Delete(&models.AIEvent{})
		if result.Error != nil {
			return total, result.Error
		}
		total += result.RowsAffected
	}
	return total, nil
}
