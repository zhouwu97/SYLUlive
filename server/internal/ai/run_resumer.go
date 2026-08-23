package ai

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"gorm.io/datatypes"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

type persistedPendingToolCall struct {
	CallID       string                       `json:"call_id"`
	ToolName     string                       `json:"tool_name"`
	ResumeKey    string                       `json:"resume_key,omitempty"`
	ConsentScope models.AIUserPermissionScope `json:"consent_scope,omitempty"`
}

// pauseRun 持久化下一次 Provider 调用的完整消息序列，并以一次 CAS 状态迁移释放当前请求协程。
func (r *Runtime) pauseRun(ctx context.Context, run *models.AIRun, pause *toolLoopPause, usage ProviderEvent) error {
	if run == nil || pause == nil || run.State != models.AIRunStateToolExecuting || len(pause.Pending) == 0 {
		return errors.New("invalid run pause")
	}
	if pause.State != models.AIRunStateWaitingDevice && pause.State != models.AIRunStateWaitingUserConsent && pause.State != models.AIRunStateWaitingEdu {
		return errors.New("invalid run pause state")
	}
	messagesJSON, err := json.Marshal(pause.Messages)
	if err != nil || len(messagesJSON) == 0 || len(messagesJSON) > 512<<10 {
		return errors.New("invalid resume messages")
	}
	pending := make([]persistedPendingToolCall, 0, len(pause.Pending))
	for _, item := range pause.Pending {
		if item.CallID == "" || item.Name == "" || item.Wait.State != pause.State {
			return errors.New("invalid pending tool call")
		}
		if pause.State == models.AIRunStateWaitingUserConsent && !item.Wait.ConsentScope.Valid() {
			return errors.New("invalid consent scope")
		}
		pending = append(pending, persistedPendingToolCall{
			CallID: item.CallID, ToolName: item.Name, ResumeKey: item.Wait.ResumeKey, ConsentScope: item.Wait.ConsentScope,
		})
	}
	pendingJSON, err := json.Marshal(pending)
	if err != nil {
		return err
	}
	usageJSON, err := json.Marshal(usage)
	if err != nil {
		return err
	}
	resume := models.AIRunResumeJob{
		ID: uuid.NewString(), RunID: run.ID, UserID: run.UserID, WaitingState: pause.State,
		MessagesJSON: datatypes.JSON(messagesJSON), PendingToolCallsJSON: datatypes.JSON(pendingJSON),
		UsageJSON: datatypes.JSON(usageJSON), Status: "waiting", ExpiresAt: run.ExpiresAt,
	}
	now := time.Now()
	err = r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		result := tx.Model(&models.AIRun{}).
			Where("id = ? AND state = ? AND state_version = ?", run.ID, models.AIRunStateToolExecuting, run.StateVersion).
			Updates(map[string]interface{}{"state": pause.State, "state_version": gorm.Expr("state_version + 1"), "updated_at": now})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return errors.New("AI run state conflict")
		}
		// 一个 Run 同一时刻只能有一个可恢复上下文；恢复后再次等待时替换旧快照。
		if err := tx.Where("run_id = ?", run.ID).Delete(&models.AIRunResumeJob{}).Error; err != nil {
			return err
		}
		return tx.Create(&resume).Error
	})
	if err != nil {
		return err
	}
	run.State = pause.State
	run.StateVersion++
	_, _ = r.appendEvent(ctx, run.ID, "run.state_changed", map[string]interface{}{"state": pause.State}, true)
	for _, pending := range pause.Pending {
		payload := make(map[string]interface{}, len(pending.Wait.Payload)+3)
		for key, value := range pending.Wait.Payload {
			payload[key] = value
		}
		payload["call_id"] = pending.CallID
		payload["tool_name"] = pending.Name
		if pending.Wait.ResumeKey != "" {
			payload["job_id"] = pending.Wait.ResumeKey
		}
		_, _ = r.appendEvent(ctx, run.ID, pending.Wait.EventType, payload, true)
	}
	return nil
}

// ResumeDeviceJob 在手机完成、拒绝或取消任务后恢复关联 Run。重复通知只会触发一次恢复。
func (r *Runtime) ResumeDeviceJob(ctx context.Context, jobID string) error {
	if r.tools == nil || strings.TrimSpace(jobID) == "" {
		return nil
	}
	var job models.DeviceToolJob
	if err := r.db.WithContext(ctx).First(&job, "id = ?", jobID).Error; err != nil {
		return err
	}
	switch job.Status {
	case models.DeviceToolJobCompleted, models.DeviceToolJobFailed, models.DeviceToolJobCancelled, models.DeviceToolJobExpired:
	default:
		return nil
	}

	var resume models.AIRunResumeJob
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("run_id = ? AND waiting_state = ? AND status = ?", job.RunID, models.AIRunStateWaitingDevice, "waiting").
			First(&resume).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return nil
			}
			return err
		}
		if !resume.ExpiresAt.After(time.Now()) {
			return r.expireResumeLocked(tx, &resume)
		}
		pending, err := decodePendingToolCalls(json.RawMessage(resume.PendingToolCallsJSON))
		if err != nil {
			return err
		}
		matched := false
		for _, item := range pending {
			if item.ResumeKey == jobID {
				matched = true
			}
			if item.ResumeKey == "" {
				return errors.New("invalid device resume key")
			}
			var current models.DeviceToolJob
			if err := tx.Select("id", "status").First(&current, "id = ? AND run_id = ?", item.ResumeKey, resume.RunID).Error; err != nil {
				return err
			}
			switch current.Status {
			case models.DeviceToolJobCompleted, models.DeviceToolJobFailed, models.DeviceToolJobCancelled, models.DeviceToolJobExpired:
			default:
				return nil
			}
		}
		if !matched {
			return nil
		}
		return tx.Model(&models.AIRunResumeJob{}).Where("id = ? AND status = ?", resume.ID, "waiting").
			Updates(map[string]interface{}{"status": "resuming", "updated_at": time.Now()}).Error
	})
	if err != nil || resume.ID == "" {
		return err
	}
	go r.executeResumedRun(resume.ID)
	return nil
}

// ResumeUserConsent 在用户主动完成教务授权并成功拉取数据后，恢复等待授权的 Run。
func (r *Runtime) ResumeUserConsent(ctx context.Context, userID uint) error {
	if r.tools == nil || userID == 0 {
		return nil
	}
	var resumes []models.AIRunResumeJob
	if err := r.db.WithContext(ctx).
		Where("user_id = ? AND waiting_state = ? AND status = ? AND expires_at > ?", userID, models.AIRunStateWaitingUserConsent, "waiting", time.Now()).
		Find(&resumes).Error; err != nil {
		return err
	}
	for _, resume := range resumes {
		pending, err := decodePendingToolCalls(json.RawMessage(resume.PendingToolCallsJSON))
		if err != nil {
			return err
		}
		legacyEduConsent := true
		for _, item := range pending {
			if item.ConsentScope.Valid() {
				legacyEduConsent = false
				break
			}
		}
		if !legacyEduConsent {
			continue
		}
		result := r.db.WithContext(ctx).Model(&models.AIRunResumeJob{}).
			Where("id = ? AND status = ?", resume.ID, "waiting").
			Updates(map[string]interface{}{"status": "resuming", "updated_at": time.Now()})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected == 1 {
			go r.executeResumedRun(resume.ID)
		}
	}
	return nil
}

// ResumeRunConsent 记录指定 Run 的一次性决定，并只恢复该 Run。
// 长期 ask 策略不会被修改，其他 Run 也不会继承本次决定。
func (r *Runtime) ResumeRunConsent(ctx context.Context, userID uint, runID string, scope models.AIUserPermissionScope, granted bool) error {
	if r == nil || r.tools == nil || userID == 0 || strings.TrimSpace(runID) == "" || !scope.Valid() {
		return &RuntimeError{Code: "invalid_run_consent", Message: "授权参数无效"}
	}
	var resume models.AIRunResumeJob
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var run models.AIRun
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("id = ? AND user_id = ?", runID, userID).First(&run).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return &RuntimeError{Code: "ai_run_not_found", Message: "AI 请求不存在"}
			}
			return err
		}
		now := time.Now()
		if run.State != models.AIRunStateWaitingUserConsent {
			return &RuntimeError{Code: "ai_run_not_waiting_consent", Message: "该请求当前不等待授权"}
		}
		if !run.ExpiresAt.After(now) {
			return &RuntimeError{Code: "ai_run_expired", Message: "该请求已过期"}
		}
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("run_id = ? AND user_id = ? AND waiting_state = ? AND status = ?", runID, userID, models.AIRunStateWaitingUserConsent, "waiting").
			First(&resume).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return &RuntimeError{Code: "ai_run_not_waiting_consent", Message: "该请求当前不等待授权"}
			}
			return err
		}
		if !resume.ExpiresAt.After(now) {
			return &RuntimeError{Code: "ai_run_expired", Message: "该请求已过期"}
		}
		pending, err := decodePendingToolCalls(json.RawMessage(resume.PendingToolCallsJSON))
		if err != nil {
			return err
		}
		for _, item := range pending {
			if item.ConsentScope != scope {
				return &RuntimeError{Code: "ai_run_consent_scope_mismatch", Message: "授权范围与当前请求不一致"}
			}
		}
		consent := models.AIRunConsent{
			RunID: runID, UserID: userID, Scope: scope, Granted: granted, ExpiresAt: run.ExpiresAt,
		}
		if err := tx.Clauses(clause.OnConflict{
			Columns: []clause.Column{{Name: "run_id"}, {Name: "scope"}},
			DoUpdates: clause.Assignments(map[string]interface{}{
				"user_id": userID, "granted": granted, "expires_at": run.ExpiresAt, "updated_at": now,
			}),
		}).Create(&consent).Error; err != nil {
			return err
		}
		result := tx.Model(&models.AIRunResumeJob{}).Where("id = ? AND status = ?", resume.ID, "waiting").
			Updates(map[string]interface{}{"status": "resuming", "updated_at": now})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return &RuntimeError{Code: "ai_run_consent_conflict", Message: "授权状态已变化，请刷新后重试", Retryable: true}
		}
		return nil
	})
	if err != nil {
		return err
	}
	go r.executeResumedRun(resume.ID)
	return nil
}

func (r *Runtime) executeResumedRun(resumeID string) {
	ctx, cancel := context.WithTimeout(context.Background(), r.config.RequestTimeout)
	defer cancel()

	var resume models.AIRunResumeJob
	if err := r.db.WithContext(ctx).Where("id = ? AND status = ?", resumeID, "resuming").First(&resume).Error; err != nil {
		return
	}
	messages, err := decodeResumeMessages(json.RawMessage(resume.MessagesJSON))
	if err != nil {
		r.failRun(resume.RunID, "invalid_resume_messages", true)
		return
	}
	pending, err := decodePendingToolCalls(json.RawMessage(resume.PendingToolCallsJSON))
	if err != nil {
		r.failRun(resume.RunID, "invalid_resume_calls", true)
		return
	}
	usage := decodeResumeUsage(json.RawMessage(resume.UsageJSON))
	toolDefinitions := routeModelToolsForMessages(messages, r.toolDefinitions())
	requiredTool, _ := requiredDecisionToolForMessages(messages, toolDefinitions)
	requiredToolCompleted := requiredTool == ""
	var run models.AIRun
	if err := r.db.WithContext(ctx).First(&run, "id = ?", resume.RunID).Error; err != nil {
		return
	}
	retryConsentTools := resume.WaitingState == models.AIRunStateWaitingUserConsent
	if retryConsentTools {
		for _, item := range pending {
			if !item.ConsentScope.Valid() {
				continue
			}
			var consent models.AIRunConsent
			if err := r.db.WithContext(ctx).Where(
				"run_id = ? AND user_id = ? AND scope = ? AND expires_at > ?",
				resume.RunID, resume.UserID, item.ConsentScope, time.Now(),
			).First(&consent).Error; err != nil {
				r.failAfterProvider(resume.RunID, true, "resume_result_unavailable", usage, 0)
				return
			}
			if !consent.Granted {
				retryConsentTools = false
				break
			}
		}
	}

	retryDeviceTools := resume.WaitingState == models.AIRunStateWaitingDevice
	if retryConsentTools || retryDeviceTools {
		if err := r.transition(ctx, &run, resume.WaitingState, models.AIRunStateToolExecuting); err != nil {
			return
		}
		waiting := make([]pendingToolWait, 0, len(pending))
		for _, item := range pending {
			_, _ = r.appendEvent(ctx, resume.RunID, "tool.executing", map[string]interface{}{
				"call_id": item.CallID, "tool_name": item.ToolName, "resumed": true,
			}, true)
			retryContext := ctx
			if retryDeviceTools {
				var deviceJob models.DeviceToolJob
				if err := r.db.WithContext(ctx).First(&deviceJob, "id = ? AND run_id = ? AND tool_call_id = ?", item.ResumeKey, resume.RunID, item.CallID).Error; err != nil {
					r.failAfterProvider(resume.RunID, true, "resume_result_unavailable", usage, 0)
					return
				}
				retryContext = withDeviceJobResumeContext(ctx, deviceJobResumeContext{
					JobID: deviceJob.ID, ToolName: deviceJob.ToolName,
					Dataset: deviceDatasetForTool(deviceJob.ToolName), Status: deviceJob.Status,
					Result: json.RawMessage(deviceJob.ResultJSON),
				})
			}
			execution, err := r.tools.RetryWaitingCall(retryContext, item.CallID, resume.RunID, resume.UserID, item.ToolName)
			if err != nil {
				r.failAfterProvider(resume.RunID, true, "resume_tool_execution_failed", usage, 0)
				return
			}
			if execution.Wait != nil {
				waiting = append(waiting, pendingToolWait{CallID: item.CallID, Name: item.ToolName, Wait: *execution.Wait})
				continue
			}
			if failureCode := fatalToolResultCode(item.ToolName, execution.Result); failureCode != "" {
				r.failAfterProvider(resume.RunID, true, failureCode, usage, 0)
				return
			}
			if item.ToolName == requiredTool {
				requiredToolCompleted = true
			}
			messages = append(messages, Message{Role: "tool", ToolCallID: item.CallID, Content: string(execution.Result)})
			_, _ = r.appendEvent(ctx, resume.RunID, "tool.completed", map[string]interface{}{
				"call_id": item.CallID, "tool_name": item.ToolName, "success": true, "cached": false, "resumed": true,
			}, true)
			r.appendPersonalDataEvidence(ctx, resume.RunID, item.CallID, execution.Result)
		}
		if len(waiting) > 0 {
			state := waiting[0].Wait.State
			consentScope := waiting[0].Wait.ConsentScope
			for _, item := range waiting[1:] {
				if item.Wait.State != state || (state == models.AIRunStateWaitingUserConsent && item.Wait.ConsentScope != consentScope) {
					r.failAfterProvider(resume.RunID, true, "resume_tool_mixed_wait_state", usage, 0)
					return
				}
			}
			if err := r.pauseRun(ctx, &run, &toolLoopPause{State: state, Messages: messages, Pending: waiting}, usage); err != nil {
				r.failAfterProvider(resume.RunID, true, "run_pause_failed", usage, 0)
			}
			return
		}
		if err := r.transition(ctx, &run, models.AIRunStateToolExecuting, models.AIRunStateToolCompleted); err != nil {
			return
		}
	} else {
		for _, item := range pending {
			result, err := r.resumeToolResult(ctx, resume, item)
			if err != nil {
				r.failAfterProvider(resume.RunID, true, "resume_result_unavailable", usage, 0)
				return
			}
			if err := r.tools.CompleteWaitingCall(ctx, item.CallID, result); err != nil {
				r.failAfterProvider(resume.RunID, true, "resume_tool_state_conflict", usage, 0)
				return
			}
			if failureCode := fatalToolResultCode(item.ToolName, result); failureCode != "" {
				r.failAfterProvider(resume.RunID, true, failureCode, usage, 0)
				return
			}
			if resume.WaitingState != models.AIRunStateWaitingUserConsent && item.ToolName == requiredTool {
				requiredToolCompleted = true
			}
			messages = append(messages, Message{Role: "tool", ToolCallID: item.CallID, Content: string(result)})
			_, _ = r.appendEvent(ctx, resume.RunID, "tool.completed", map[string]interface{}{
				"call_id": item.CallID, "tool_name": item.ToolName, "success": true, "cached": false,
			}, true)
			r.appendPersonalDataEvidence(ctx, resume.RunID, item.CallID, result)
		}
		if err := r.transition(ctx, &run, resume.WaitingState, models.AIRunStateToolCompleted); err != nil {
			return
		}
	}
	if err := r.transition(ctx, &run, models.AIRunStateToolCompleted, models.AIRunStatePlanning); err != nil {
		return
	}
	// 新的等待会在 pauseRun 中替换该行；终态路径则只删除当前恢复行。
	_ = r.db.WithContext(ctx).Where("id = ? AND status = ?", resume.ID, "resuming").Delete(&models.AIRunResumeJob{}).Error

	startedAt := time.Now()
	outcome := r.executeToolLoop(ctx, &run, messages, toolDefinitions, requiredTool, requiredToolCompleted)
	usage = mergeProviderUsage(usage, outcome.usage)
	if outcome.cancelled {
		r.finalizeCancelled(run.ID, true, usage, time.Since(startedAt))
		return
	}
	if outcome.pause != nil {
		if err := r.pauseRun(ctx, &run, outcome.pause, usage); err != nil {
			r.failAfterProvider(run.ID, true, "run_pause_failed", usage, time.Since(startedAt))
		}
		return
	}
	if outcome.failureCode != "" || strings.TrimSpace(outcome.answer) == "" {
		code := outcome.failureCode
		if code == "" {
			code = ProviderErrorInvalid
		}
		r.failAfterProvider(run.ID, true, code, usage, time.Since(startedAt))
		return
	}
	r.markQuotaConsumed(run.ID)
	_, _ = r.appendEvent(ctx, run.ID, "answer.delta", map[string]interface{}{"text": outcome.answer}, false)
	r.completeRun(run.ID, outcome.answer, nil, usage, time.Since(startedAt), false)
}

func (r *Runtime) resumeToolResult(ctx context.Context, resume models.AIRunResumeJob, pending persistedPendingToolCall) (json.RawMessage, error) {
	if resume.WaitingState == models.AIRunStateWaitingUserConsent {
		if !pending.ConsentScope.Valid() {
			return json.RawMessage(`{"status":"completed","consent_granted":true,"instruction":"教务授权已完成，请重新读取最新数据"}`), nil
		}
		var consent models.AIRunConsent
		if err := r.db.WithContext(ctx).Where(
			"run_id = ? AND user_id = ? AND scope = ? AND expires_at > ?",
			resume.RunID, resume.UserID, pending.ConsentScope, time.Now(),
		).First(&consent).Error; err != nil {
			return nil, err
		}
		instruction := "用户已允许本次访问，请重新调用工具读取已授权数据"
		if !consent.Granted {
			instruction = "用户拒绝了本次访问，不要再次请求或假设可读取该数据"
		}
		return json.Marshal(map[string]interface{}{
			"status": "completed", "consent_granted": consent.Granted, "scope": consent.Scope, "instruction": instruction,
		})
	}
	if resume.WaitingState != models.AIRunStateWaitingDevice || pending.ResumeKey == "" {
		return nil, errors.New("unsupported resume state")
	}
	var job models.DeviceToolJob
	if err := r.db.WithContext(ctx).First(&job, "id = ? AND run_id = ? AND tool_call_id = ?", pending.ResumeKey, resume.RunID, pending.CallID).Error; err != nil {
		return nil, err
	}
	if job.Status == models.DeviceToolJobCompleted && json.Valid(job.ResultJSON) {
		return json.RawMessage(job.ResultJSON), nil
	}
	code := strings.TrimSpace(job.ErrorCode)
	if code == "" {
		code = "device_job_failed"
	}
	return json.Marshal(map[string]string{"status": "failed", "error_code": code})
}

func decodeResumeMessages(raw json.RawMessage) ([]Message, error) {
	var messages []Message
	if len(raw) == 0 || json.Unmarshal(raw, &messages) != nil || len(messages) == 0 {
		return nil, errors.New("invalid resume messages")
	}
	return messages, nil
}

func decodePendingToolCalls(raw json.RawMessage) ([]persistedPendingToolCall, error) {
	var calls []persistedPendingToolCall
	if len(raw) == 0 || json.Unmarshal(raw, &calls) != nil || len(calls) == 0 {
		return nil, errors.New("invalid pending tool calls")
	}
	for _, call := range calls {
		if call.CallID == "" || call.ToolName == "" {
			return nil, errors.New("invalid pending tool call")
		}
	}
	return calls, nil
}

func decodeResumeUsage(raw json.RawMessage) ProviderEvent {
	var usage ProviderEvent
	_ = json.Unmarshal(raw, &usage)
	return usage
}

func mergeProviderUsage(left, right ProviderEvent) ProviderEvent {
	left.InputTokens += right.InputTokens
	left.OutputTokens += right.OutputTokens
	left.CacheHitTokens += right.CacheHitTokens
	return left
}

func (r *Runtime) expireResumeLocked(tx *gorm.DB, resume *models.AIRunResumeJob) error {
	if err := tx.Model(&models.AIRun{}).Where("id = ? AND state = ?", resume.RunID, resume.WaitingState).
		Updates(map[string]interface{}{"state": models.AIRunStateExpired, "state_version": gorm.Expr("state_version + 1"), "completed_at": time.Now()}).Error; err != nil {
		return err
	}
	return tx.Model(&models.AIRunResumeJob{}).Where("id = ?", resume.ID).Update("status", "expired").Error
}
