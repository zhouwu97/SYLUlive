package ai

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"io"
	"math"
	"shenliyuan/internal/models"
	"time"
)

type LocalAnalysisSummary struct {
	Kind        string   `json:"kind"`
	CourseCount int      `json:"course_count"`
	Credits     float64  `json:"credits"`
	Average     *float64 `json:"average,omitempty"`
	GPA         *float64 `json:"gpa,omitempty"`
}
type LocalAnalysisRequest struct {
	Question string               `json:"question"`
	Model    string               `json:"model"`
	Summary  LocalAnalysisSummary `json:"summary"`
	DataTime time.Time            `json:"data_time"`
	Consent  struct {
		Accepted   bool      `json:"accepted"`
		AcceptedAt time.Time `json:"accepted_at"`
		RequestID  string    `json:"request_id"`
	} `json:"consent"`
}

func (r *Runtime) LocalAnalysisModel() string { return r.config.Model }

// LocalAnalysis 不创建会话、消息、Run 或正文事件，仅复用配额、预算与用量表。
func (r *Runtime) LocalAnalysis(ctx context.Context, userID uint, input LocalAnalysisRequest, emit func(string, interface{}) error) (err error) {
	now := time.Now()
	if userID == 0 {
		return &RuntimeError{Code: "authentication_required", Message: "需要登录"}
	}
	if !input.Consent.Accepted || input.Consent.AcceptedAt.Before(now.Add(-10*time.Minute)) || input.Consent.AcceptedAt.After(now.Add(time.Minute)) {
		return &RuntimeError{Code: "consent_required", Message: "请重新确认本次个人摘要发送"}
	}
	if _, e := uuid.Parse(input.Consent.RequestID); e != nil {
		return &RuntimeError{Code: "invalid_request", Message: "授权编号无效"}
	}
	s := input.Summary
	finite := func(n float64) bool { return !math.IsNaN(n) && !math.IsInf(n, 0) }
	if s.Kind != "grade_statistics" || s.CourseCount < 1 || s.CourseCount > 5000 || !finite(s.Credits) || s.Credits < 0 || s.Credits > 1000 || s.Average != nil && (!finite(*s.Average) || *s.Average < 0 || *s.Average > 100) || s.GPA != nil && (!finite(*s.GPA) || *s.GPA < 0 || *s.GPA > 10) || input.DataTime.IsZero() || input.DataTime.After(now.Add(time.Minute)) {
		return &RuntimeError{Code: "invalid_summary", Message: "个人摘要字段不正确"}
	}
	if input.Model != "" && input.Model != r.config.Model {
		return &RuntimeError{Code: "invalid_model", Message: "请选择服务器允许的模型"}
	}
	question, _, e := NormalizeUserMessage(input.Question, r.config.MaxMessageChars)
	if e != nil {
		return e
	}
	if r.provider == nil {
		return &RuntimeError{Code: "provider_unavailable", Message: "当前服务尚未启用独立个人分析通道"}
	}
	ctx, cancel := context.WithTimeout(ctx, r.config.RequestTimeout)
	defer cancel()
	runID := input.Consent.RequestID
	// 与公共对话使用相同的用户级数据库锁和配额账本，避免两个入口相互绕过限流。
	err = r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if tx.Dialector.Name() == "postgres" {
			if e := tx.Exec("SELECT pg_advisory_xact_lock(?)", int64(userID)).Error; e != nil {
				return e
			}
		}
		var duplicate int64
		if e := tx.Model(&models.AIQuotaEntry{}).Where("run_id = ?", runID).Count(&duplicate).Error; e != nil {
			return e
		}
		if duplicate > 0 {
			return &RuntimeError{Code: "consent_used", Message: "此次授权已使用，请重新确认后重试"}
		}
		unlimited, e := r.isQuotaUnlimited(tx, userID)
		if e != nil {
			return e
		}
		if !unlimited {
			var count int64
			if e = tx.Model(&models.AIQuotaEntry{}).Where("user_id = ? AND status IN ? AND created_at > ?", userID, []string{"reserved", "consumed"}, now.Add(-time.Hour)).Count(&count).Error; e != nil {
				return e
			}
			if count >= int64(r.config.HourlyMessageLimit) {
				return &RuntimeError{Code: "ai_quota_exceeded", Message: "最近 60 分钟的可用次数已用完"}
			}
		}
		if e = tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&models.AIUserBudget{UserID: userID, LimitMicroYuan: r.config.DefaultBudgetLimitMicroYuan}).Error; e != nil {
			return e
		}
		result := tx.Model(&models.AIUserBudget{}).Where("user_id = ? AND used_micro_yuan + reserved_micro_yuan + ? <= limit_micro_yuan", userID, r.config.ReservationMicroYuan).Update("reserved_micro_yuan", gorm.Expr("reserved_micro_yuan + ?", r.config.ReservationMicroYuan))
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return &RuntimeError{Code: "ai_budget_exceeded", Message: "当前 AI 服务额度已达到平台限制"}
		}
		if e = tx.Create(&models.AIBudgetReservation{ID: uuid.NewString(), RunID: runID, UserID: userID, ReservedMicroYuan: r.config.ReservationMicroYuan, Status: "reserved", ExpiresAt: now.Add(r.config.RequestTimeout + 5*time.Minute)}).Error; e != nil {
			return e
		}
		return tx.Create(&models.AIQuotaEntry{UserID: userID, RunID: runID, Status: "reserved", CreatedAt: now}).Error
	})
	if err != nil {
		return err
	}
	var usage ProviderEvent
	started := false
	defer func() {
		if !started {
			r.releaseQuotaAndBudget(runID)
			return
		}
		code := ""
		if err != nil {
			code = "local_analysis_failed"
		}
		if ctx.Err() != nil {
			code = "context_cancelled"
		}
		if settlement := r.settleLocalAnalysis(runID, userID, usage, time.Since(now), code); settlement != nil && err == nil {
			err = settlement
		}
	}()
	raw, _ := json.Marshal(input.Summary)
	stream, e := r.provider.Start(ctx, ProviderRequest{Model: r.config.Model, Messages: []Message{{Role: "system", Content: "仅根据用户本次授权的学业统计摘要给出建议。摘要不是学校认定，不推测身份、不虚构毕业要求。不得调用工具或索取密码。"}, {Role: "user", Content: question + "\n本次授权摘要：" + string(raw)}}, MaxTokens: r.config.MaxOutputTokens, Temperature: 0.2})
	if e != nil {
		return &RuntimeError{Code: "provider_unavailable", Message: "模型服务暂不可用"}
	}
	defer stream.Close()
	started = true
	for {
		event, e := stream.Next(ctx)
		if errors.Is(e, io.EOF) {
			break
		}
		if e != nil {
			return &RuntimeError{Code: "provider_failed", Message: "生成中断，请重新确认摘要后重试"}
		}
		switch event.Type {
		case ProviderEventTextDelta:
			if e = emit("answer.delta", map[string]string{"text": event.Text}); e != nil {
				return e
			}
		case ProviderEventUsage:
			usage = event
		case ProviderEventCompleted:
			return emit("run.completed", map[string]bool{"completed": true})
		}
	}
	return emit("run.completed", map[string]bool{"completed": true})
}
func (r *Runtime) settleLocalAnalysis(runID string, userID uint, usage ProviderEvent, latency time.Duration, code string) error {
	actual := (int64(usage.InputTokens)*r.config.InputPriceMicroYuanPerMillion+999999)/1000000 + (int64(usage.OutputTokens)*r.config.OutputPriceMicroYuanPerMillion+999999)/1000000
	// 未收到用量时按预留额度计费，防止中断生成成为免费绕过预算的入口。
	if !usage.UsageAvailable {
		actual = r.config.ReservationMicroYuan
	}
	return r.db.Transaction(func(tx *gorm.DB) error {
		var reservation models.AIBudgetReservation
		if e := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("run_id = ? AND status = ?", runID, "reserved").First(&reservation).Error; e != nil {
			return e
		}
		now := time.Now()
		if e := tx.Model(&models.AIUserBudget{}).Where("user_id = ?", userID).Updates(map[string]interface{}{"reserved_micro_yuan": gorm.Expr("reserved_micro_yuan - ?", reservation.ReservedMicroYuan), "used_micro_yuan": gorm.Expr("used_micro_yuan + ?", actual)}).Error; e != nil {
			return e
		}
		if e := tx.Model(&reservation).Updates(map[string]interface{}{"status": "settled", "actual_micro_yuan": actual, "settled_at": now}).Error; e != nil {
			return e
		}
		if e := tx.Model(&models.AIQuotaEntry{}).Where("run_id = ?", runID).Update("status", "consumed").Error; e != nil {
			return e
		}
		return tx.Create(&models.AIUsageRecord{RunID: runID, UserHash: r.hashUserID(userID), Provider: r.config.ProviderName, Model: r.config.Model, Purpose: "local_analysis", InputTokens: usage.InputTokens, OutputTokens: usage.OutputTokens, CostMicroYuan: actual, LatencyMilliseconds: latency.Milliseconds(), ErrorClass: code}).Error
	})
}
