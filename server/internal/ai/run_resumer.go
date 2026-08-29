package ai

import (
	"context"
	"encoding/json"
	"errors"
	"log"
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
	r.appendDeviceResumeTrace(ctx, job.RunID, deviceJobTerminalEvent(job.Status), map[string]interface{}{
		"job_id": job.ID, "tool_call_id": job.ToolCallID, "tool_name": job.ToolName,
		"datasets": deviceDatasetsForTool(job.ToolName), "status": job.Status,
		"error_code":   job.ErrorCode,
		"result_bytes": len(job.ResultJSON), "result_hash": job.ResultHash,
	})

	var resume models.AIRunResumeJob
	claimed := false
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
		result := tx.Model(&models.AIRunResumeJob{}).Where("id = ? AND status = ?", resume.ID, "waiting").
			Updates(map[string]interface{}{"status": "resuming", "updated_at": time.Now()})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected == 1 {
			claimed = true
		}
		return nil
	})
	if err != nil {
		log.Printf("[AI_DEVICE_RESUME_FAILED] job_id=%s run_id=%s err=%v", job.ID, job.RunID, err)
		return err
	}
	if resume.ID == "" || !claimed {
		return nil
	}
	r.appendDeviceResumeTrace(ctx, resume.RunID, "ai.device.resume.claimed", map[string]interface{}{
		"job_id": job.ID, "resume_id": resume.ID, "tool_call_id": job.ToolCallID,
		"tool_name": job.ToolName, "datasets": deviceDatasetsForTool(job.ToolName),
		"status": "resuming", "waiting_state": resume.WaitingState,
	})
	go r.executeResumedRun(resume.ID)
	return nil
}

// ReconcileWaitingDeviceJobs 兜底扫描设备已完成但 Run 仍在等待恢复的任务。
// Handler 回调即使因瞬态数据库/CAS 错误失败，也不会让 Run 永久停在 waiting_device。
func (r *Runtime) ReconcileWaitingDeviceJobs(ctx context.Context, limit int) (int, error) {
	if r == nil || r.db == nil {
		return 0, nil
	}
	if limit <= 0 {
		limit = 50
	}
	var jobs []models.DeviceToolJob
	if err := r.db.WithContext(ctx).
		Where("status IN ?", []string{
			models.DeviceToolJobCompleted, models.DeviceToolJobFailed,
			models.DeviceToolJobCancelled, models.DeviceToolJobExpired,
		}).
		Where("EXISTS (SELECT 1 FROM ai_run_resume_jobs WHERE ai_run_resume_jobs.run_id = device_tool_jobs.run_id AND ai_run_resume_jobs.waiting_state = ? AND ai_run_resume_jobs.status = ?)", models.AIRunStateWaitingDevice, "waiting").
		Order("updated_at ASC").Limit(limit).Find(&jobs).Error; err != nil {
		return 0, err
	}
	resumed := 0
	for _, job := range jobs {
		if err := r.ResumeDeviceJob(ctx, job.ID); err != nil {
			log.Printf("[AI_DEVICE_RECONCILE_FAILED] job_id=%s run_id=%s err=%v", job.ID, job.RunID, err)
			continue
		}
		resumed++
	}
	return resumed, nil
}

func (r *Runtime) appendDeviceResumeTrace(ctx context.Context, runID, eventType string, payload map[string]interface{}) {
	if strings.TrimSpace(runID) == "" {
		return
	}
	if _, err := r.appendEvent(ctx, runID, eventType, payload, true); err != nil {
		log.Printf("[AI_TRACE_APPEND_FAILED] run_id=%s event=%s err=%v", runID, eventType, err)
	}
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
	agentState, stateErr := r.loadRuntimeAgentState(ctx, &run, "resume")
	if stateErr != nil {
		r.failRun(resume.RunID, "agent_state_corrupt", true)
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
			_, _ = r.appendEvent(ctx, resume.RunID, "tool.executing", r.agentTracePayload(&run, map[string]interface{}{
				"call_id": item.CallID, "tool_name": item.ToolName, "resumed": true,
			}, 0, 0), true)
			retryContext := ctx
			if retryDeviceTools {
				var deviceJob models.DeviceToolJob
				if err := r.db.WithContext(ctx).First(&deviceJob, "id = ? AND run_id = ? AND tool_call_id = ?", item.ResumeKey, resume.RunID, item.CallID).Error; err != nil {
					r.failAfterProvider(resume.RunID, true, "resume_result_unavailable", usage, 0)
					return
				}
				r.appendDeviceResumeTrace(ctx, resume.RunID, "ai.device.result.consumed", map[string]interface{}{
					"job_id": deviceJob.ID, "tool_call_id": item.CallID, "tool_name": deviceJob.ToolName,
					"datasets": deviceDatasetsForTool(deviceJob.ToolName), "status": deviceJob.Status,
					"error_code":   deviceJob.ErrorCode,
					"result_bytes": len(deviceJob.ResultJSON), "result_hash": deviceJob.ResultHash,
				})
				retryContext = withDeviceJobResumeContext(ctx, deviceJobResumeContext{
					JobID: deviceJob.ID, ToolName: deviceJob.ToolName,
					Dataset: deviceDatasetForTool(deviceJob.ToolName), Status: deviceJob.Status,
					ErrorCode: deviceJob.ErrorCode,
					Result:    json.RawMessage(deviceJob.ResultJSON),
				})
			}
			cachedResult, alreadyCommitted, readBackErr := r.readCommittedToolResult(ctx, item.CallID, resume.RunID, resume.UserID, item.ToolName)
			if readBackErr != nil {
				r.failAfterProvider(resume.RunID, true, "resume_result_unavailable", usage, 0)
				return
			}
			var execution ToolExecutionResult
			var err error
			if alreadyCommitted {
				// 进程可能在工具事务提交后、Run 快照落盘前退出；优先使用真实
				// Tool Call 结果，不能把已提交的副作用/刷新再次执行。
				execution = ToolExecutionResult{Result: cachedResult}
			} else {
				execution, err = r.tools.RetryWaitingCall(retryContext, item.CallID, resume.RunID, resume.UserID, item.ToolName)
			}
			if err != nil {
				r.failAfterProvider(resume.RunID, true, "resume_tool_execution_failed", usage, 0)
				return
			}
			if execution.Wait != nil {
				r.appendDeviceResumeTrace(ctx, resume.RunID, "ai.tool.retry.waiting_again", map[string]interface{}{
					"call_id": item.CallID, "tool_name": item.ToolName,
					"waiting_state": execution.Wait.State,
					"resume_key":    execution.Wait.ResumeKey,
				})
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
			addRuntimeObservation(&agentState, item.ToolName, execution.Result, time.Now())
			agentState.PlanVersion++
			if err := r.persistRuntimeAgentState(ctx, &run, agentState); err != nil {
				r.failAfterProvider(resume.RunID, true, "agent_state_persist_failed", usage, 0)
				return
			}
			messages = append(messages, Message{Role: "tool", ToolCallID: item.CallID, Content: string(toolResultForModel(item.ToolName, execution.Result))})
			eventPayload := map[string]interface{}{
				"call_id": item.CallID, "tool_name": item.ToolName, "success": true, "cached": false, "resumed": true,
			}
			if actions := academicRiskOptionalActions(item.ToolName, execution.Result); len(actions) > 0 {
				eventPayload["optional_actions"] = actions
			}
			_, _ = r.appendEvent(ctx, resume.RunID, "tool.completed", r.agentTracePayload(&run, eventPayload, 0, 0), true)
			r.appendDeviceResumeTrace(ctx, resume.RunID, "ai.tool.retry.completed", map[string]interface{}{
				"call_id": item.CallID, "tool_name": item.ToolName, "status": "completed",
			})
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
			result, alreadyCommitted, err := r.readCommittedToolResult(ctx, item.CallID, resume.RunID, resume.UserID, item.ToolName)
			if err != nil {
				r.failAfterProvider(resume.RunID, true, "resume_result_unavailable", usage, 0)
				return
			}
			if !alreadyCommitted {
				result, err = r.resumeToolResult(ctx, resume, item)
				if err != nil {
					r.failAfterProvider(resume.RunID, true, "resume_result_unavailable", usage, 0)
					return
				}
				if err := r.tools.CompleteWaitingCall(ctx, item.CallID, result); err != nil {
					r.failAfterProvider(resume.RunID, true, "resume_tool_state_conflict", usage, 0)
					return
				}
			}
			if failureCode := fatalToolResultCode(item.ToolName, result); failureCode != "" {
				r.failAfterProvider(resume.RunID, true, failureCode, usage, 0)
				return
			}
			if resume.WaitingState != models.AIRunStateWaitingUserConsent && item.ToolName == requiredTool {
				requiredToolCompleted = true
			}
			addRuntimeObservation(&agentState, item.ToolName, result, time.Now())
			agentState.PlanVersion++
			if err := r.persistRuntimeAgentState(ctx, &run, agentState); err != nil {
				r.failAfterProvider(resume.RunID, true, "agent_state_persist_failed", usage, 0)
				return
			}
			messages = append(messages, Message{Role: "tool", ToolCallID: item.CallID, Content: string(toolResultForModel(item.ToolName, result))})
			eventPayload := map[string]interface{}{
				"call_id": item.CallID, "tool_name": item.ToolName, "success": true, "cached": false,
			}
			if actions := academicRiskOptionalActions(item.ToolName, result); len(actions) > 0 {
				eventPayload["optional_actions"] = actions
			}
			_, _ = r.appendEvent(ctx, resume.RunID, "tool.completed", r.agentTracePayload(&run, eventPayload, 0, 0), true)
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
	r.appendDeviceResumeTrace(ctx, run.ID, "ai.provider.started", map[string]interface{}{
		"state": run.State, "planning_round": run.PlanningRound,
		"constraint_version": run.ConstraintVersion, "plan_version": run.PlanVersion,
	})
	outcome := r.executeToolLoop(ctx, &run, messages, toolDefinitions, requiredTool, requiredToolCompleted, &agentState)
	usage = mergeProviderUsage(usage, outcome.usage)
	if outcome.cancelled {
		r.appendDeviceResumeTrace(ctx, run.ID, "ai.provider.failed", map[string]interface{}{
			"reason": "cancelled", "duration_ms": time.Since(startedAt).Milliseconds(),
		})
		r.finalizeCancelled(run.ID, true, usage, time.Since(startedAt))
		return
	}
	if outcome.pause != nil {
		r.appendDeviceResumeTrace(ctx, run.ID, "ai.provider.completed", map[string]interface{}{
			"result": "waiting", "duration_ms": time.Since(startedAt).Milliseconds(),
		})
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
		r.appendDeviceResumeTrace(ctx, run.ID, "ai.provider.failed", map[string]interface{}{
			"error_code": code, "duration_ms": time.Since(startedAt).Milliseconds(),
		})
		r.failAfterProvider(run.ID, true, code, usage, time.Since(startedAt))
		return
	}
	r.appendDeviceResumeTrace(ctx, run.ID, "ai.provider.completed", map[string]interface{}{
		"result": "answer", "duration_ms": time.Since(startedAt).Milliseconds(),
	})
	r.markQuotaConsumed(run.ID)
	// 与主路径一致：已实时广播增量时不再重复发送全量 answer.delta。
	if !outcome.deltaEmitted {
		_, _ = r.appendEvent(ctx, run.ID, "answer.delta", map[string]interface{}{"text": outcome.answer}, false)
	}
	r.completeRun(run.ID, outcome.answer, nil, usage, time.Since(startedAt), false)
}

func deviceJobTerminalEvent(status string) string {
	switch status {
	case models.DeviceToolJobCompleted:
		return "ai.device.job.succeeded"
	case models.DeviceToolJobFailed:
		return "ai.device.job.failed"
	case models.DeviceToolJobCancelled:
		return "ai.device.job.cancelled"
	case models.DeviceToolJobExpired:
		return "ai.device.job.expired"
	default:
		return "ai.device.job.terminal"
	}
}

// readCommittedToolResult 是恢复路径的副作用 read-back。Tool Call 已完成时，
// 即使 Run 的 AgentStateJSON 尚未成功写入，也只能消费数据库中的已提交结果。
func (r *Runtime) readCommittedToolResult(ctx context.Context, callID, runID string, userID uint, toolName string) (json.RawMessage, bool, error) {
	var call models.AIToolCall
	if err := r.db.WithContext(ctx).Where("call_id = ?", callID).First(&call).Error; err != nil {
		return nil, false, err
	}
	canonicalToolName := toolName
	if r.tools != nil {
		if mapped, ok := r.tools.modelToolNames[toolName]; ok {
			canonicalToolName = mapped
		}
	}
	if call.RunID != runID || call.UserID != userID || call.ToolName != canonicalToolName {
		return nil, false, errors.New("resume_tool_identity_conflict")
	}
	if call.Status != "completed" {
		return nil, false, nil
	}
	if len(call.ResultJSON) == 0 || !json.Valid(call.ResultJSON) {
		return nil, false, errors.New("resume_committed_result_invalid")
	}
	return append(json.RawMessage(nil), call.ResultJSON...), true, nil
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
	left.UsageAvailable = left.UsageAvailable || right.UsageAvailable
	return left
}

func (r *Runtime) expireResumeLocked(tx *gorm.DB, resume *models.AIRunResumeJob) error {
	if err := tx.Model(&models.AIRun{}).Where("id = ? AND state = ?", resume.RunID, resume.WaitingState).
		Updates(map[string]interface{}{"state": models.AIRunStateExpired, "state_version": gorm.Expr("state_version + 1"), "completed_at": time.Now()}).Error; err != nil {
		return err
	}
	return tx.Model(&models.AIRunResumeJob{}).Where("id = ?", resume.ID).Update("status", "expired").Error
}
