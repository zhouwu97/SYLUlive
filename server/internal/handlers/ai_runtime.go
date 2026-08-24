package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"gorm.io/gorm"

	"shenliyuan/internal/ai"
	"shenliyuan/internal/models"
)

type AIRuntimeHandler struct {
	db      *gorm.DB
	runtime *ai.Runtime
}

func NewAIRuntimeHandler(db *gorm.DB, runtime *ai.Runtime) *AIRuntimeHandler {
	return &AIRuntimeHandler{db: db, runtime: runtime}
}

type createAIRunRequest struct {
	ConversationID  string                   `json:"conversation_id"`
	ClientRequestID string                   `json:"client_request_id"`
	Message         string                   `json:"message"`
	AppVersion      string                   `json:"app_version"`
	AgentContext    *ai.AgentContextEnvelope `json:"context"`
}

type submitAIRunConsentRequest struct {
	Scope   models.AIUserPermissionScope `json:"scope"`
	Granted *bool                        `json:"granted"`
}

type submitAIRunFeedbackRequest struct {
	Signal        string `json:"signal"`
	FailureReason string `json:"failure_reason"`
	Note          string `json:"note"`
}

func (h *AIRuntimeHandler) CreateRun(c *gin.Context) {
	var request createAIRunRequest
	if err := decodeStrictJSON(c, &request, 16<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request", "message": "请求格式错误"})
		return
	}
	if strings.TrimSpace(request.AppVersion) == "" {
		request.AppVersion = strings.TrimSpace(c.GetHeader("X-App-Version"))
	}
	run, duplicate, err := h.runtime.CreateRun(c.Request.Context(), c.GetUint("user_id"), ai.CreateRunRequest{
		ConversationID: request.ConversationID, ClientRequestID: request.ClientRequestID, Message: request.Message,
		AppVersion:   request.AppVersion,
		AgentContext: request.AgentContext,
	})
	if err != nil {
		logCreateRunOutcome(c, request.ClientRequestID, "", false, err)
		writeAIRuntimeError(c, err)
		return
	}
	status := http.StatusAccepted
	if duplicate {
		status = http.StatusOK
	}
	logCreateRunOutcome(c, request.ClientRequestID, run.ID, duplicate, nil)
	c.JSON(status, gin.H{"run": run, "duplicate": duplicate})
}

// logCreateRunOutcome 只记录链路定位所需的标识，不记录问题正文、令牌或个人数据。
// 客户端在请求头带同一个 ID，据此可以区分：请求根本没到达服务端、
// 服务端处理超时、还是服务端已返回但响应在回程丢失。
func logCreateRunOutcome(c *gin.Context, clientRequestID, runID string, duplicate bool, err error) {
	headerID := strings.TrimSpace(c.GetHeader("X-Client-Request-ID"))
	if headerID == "" {
		headerID = "-"
	}
	if clientRequestID = strings.TrimSpace(clientRequestID); clientRequestID == "" {
		clientRequestID = "-"
	}
	outcome := "created"
	switch {
	case err != nil:
		outcome = "failed"
	case duplicate:
		outcome = "duplicate"
	}
	detail := ""
	if err != nil {
		var runtimeErr *ai.RuntimeError
		if errors.As(err, &runtimeErr) {
			detail = " code=" + runtimeErr.Code
		} else {
			detail = " code=internal"
		}
	}
	log.Printf("ai_create_run user_id=%d client_request_id=%s header_request_id=%s run_id=%s outcome=%s%s",
		c.GetUint("user_id"), clientRequestID, headerID, defaultDash(runID), outcome, detail)
}

func defaultDash(value string) string {
	if strings.TrimSpace(value) == "" {
		return "-"
	}
	return value
}

func (h *AIRuntimeHandler) GetRun(c *gin.Context) {
	run, err := h.runtime.GetRun(c.Request.Context(), c.GetUint("user_id"), c.Param("id"))
	if err != nil {
		writeAIRuntimeError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"run": run})
}

// GetRunSources 返回 Run 完成时持久化的公开来源与个人数据来源元数据。
// 个人来源可包含本次送入分析器的去身份化输入，但不包含账号、凭据或原始教务响应。
func (h *AIRuntimeHandler) GetRunSources(c *gin.Context) {
	runID := strings.TrimSpace(c.Param("id"))
	var run models.AIRun
	if err := h.db.WithContext(c.Request.Context()).
		Where("id = ? AND user_id = ?", runID, c.GetUint("user_id")).
		First(&run).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"code": "ai_run_not_found", "message": "Run 不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ai_source_read_failed", "message": "读取回答来源失败"})
		return
	}

	var event models.AIEvent
	query := h.db.WithContext(c.Request.Context()).
		Where("run_id = ? AND type = ?", run.ID, "sources.ready").
		Order("seq DESC").
		First(&event)
	personalEvidence, evidenceErr := h.personalDataEvidence(c.Request.Context(), run.ID)
	if evidenceErr != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ai_source_read_failed", "message": "读取回答来源失败"})
		return
	}
	if errors.Is(query.Error, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusOK, gin.H{"run_id": run.ID, "sources": []ai.SourceCard{}, "personal_data_evidence": personalEvidence})
		return
	}
	if query.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ai_source_read_failed", "message": "读取回答来源失败"})
		return
	}

	var payload struct {
		Sources []ai.SourceCard `json:"sources"`
	}
	if err := json.Unmarshal(event.Payload, &payload); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ai_source_read_failed", "message": "回答来源格式错误"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"run_id": run.ID, "sources": payload.Sources, "personal_data_evidence": personalEvidence})
}

func (h *AIRuntimeHandler) personalDataEvidence(ctx context.Context, runID string) ([]map[string]interface{}, error) {
	var events []models.AIEvent
	if err := h.db.WithContext(ctx).Where("run_id = ? AND type = ?", runID, "personal_data.evidence").Order("seq ASC").Find(&events).Error; err != nil {
		return nil, err
	}
	result := make([]map[string]interface{}, 0)
	seen := map[string]struct{}{}
	for _, event := range events {
		var payload struct {
			Evidence []map[string]interface{} `json:"evidence"`
		}
		if json.Unmarshal(event.Payload, &payload) != nil {
			continue
		}
		for _, item := range payload.Evidence {
			encoded, _ := json.Marshal(item)
			key := string(encoded)
			if _, exists := seen[key]; exists {
				continue
			}
			seen[key] = struct{}{}
			result = append(result, item)
		}
	}
	return result, nil
}

// SubmitRunConsent 只接受当前 JWT 用户对指定等待中 Run 的一次性决定。
func (h *AIRuntimeHandler) SubmitRunConsent(c *gin.Context) {
	var request submitAIRunConsentRequest
	if err := decodeStrictJSON(c, &request, 4<<10); err != nil || request.Granted == nil || !request.Scope.Valid() {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_run_consent", "message": "授权参数无效"})
		return
	}
	if err := h.runtime.ResumeRunConsent(
		c.Request.Context(), c.GetUint("user_id"), c.Param("id"), request.Scope, *request.Granted,
	); err != nil {
		writeAIRuntimeError(c, err)
		return
	}
	c.JSON(http.StatusAccepted, gin.H{
		"run_id": c.Param("id"), "scope": request.Scope, "granted": *request.Granted,
	})
}

// GetSourceChunk 返回已发布知识文档的单个证据分块正文。
// 来源卡片只在用户展开时读取，避免把完整政策正文随每次回答推送给客户端。
func (h *AIRuntimeHandler) GetSourceChunk(c *gin.Context) {
	chunkID, err := strconv.ParseUint(c.Param("chunk_id"), 10, 64)
	if err != nil || chunkID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_source", "message": "来源参数无效"})
		return
	}
	var result struct {
		ChunkID      uint64 `json:"chunk_id"`
		DocumentID   uint   `json:"document_id"`
		Title        string `json:"title"`
		Content      string `json:"content"`
		SectionTitle string `json:"section_title,omitempty"`
		Locator      string `json:"locator,omitempty"`
	}
	query := h.db.Table("ai_knowledge_chunks AS c").
		Select("c.id AS chunk_id, c.document_id, d.title, c.content, c.section_title, c.source_locator AS locator").
		Joins("JOIN ai_knowledge_documents AS d ON d.id = c.document_id AND d.deleted_at IS NULL").
		Where("c.id = ? AND d.status = ?", chunkID, models.KnowledgeStatusPublished).
		Limit(1).Scan(&result)
	if query.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "source_unavailable", "message": "来源正文暂时不可用"})
		return
	}
	if result.ChunkID == 0 {
		c.JSON(http.StatusNotFound, gin.H{"code": "source_not_found", "message": "来源正文不存在"})
		return
	}
	c.Header("Cache-Control", "private, max-age=300")
	c.JSON(http.StatusOK, result)
}

func (h *AIRuntimeHandler) CancelRun(c *gin.Context) {
	if !requireEmptyKnowledgeActionBody(c) {
		return
	}
	run, err := h.runtime.Cancel(c.Request.Context(), c.GetUint("user_id"), c.Param("id"))
	if err != nil {
		writeAIRuntimeError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"run": run})
}

// SubmitRunFeedback 接收有限枚举的用户信号和失败归因，不接受纠正正文或诊断备注。
func (h *AIRuntimeHandler) SubmitRunFeedback(c *gin.Context) {
	var request submitAIRunFeedbackRequest
	if err := decodeStrictJSON(c, &request, 2<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request", "message": "请求格式错误"})
		return
	}
	userID, runID := c.GetUint("user_id"), c.Param("id")
	result := gin.H{"run_id": runID}
	signal := ai.AgentUserSignal(strings.TrimSpace(request.Signal))
	reason := ai.AgentFailureReason(strings.TrimSpace(request.FailureReason))
	if request.Signal != "" && !signal.Valid() {
		writeAIRuntimeError(c, &ai.RuntimeError{Code: "invalid_agent_user_signal", Message: "反馈信号无效"})
		return
	}
	if request.FailureReason != "" && !reason.Valid() {
		writeAIRuntimeError(c, &ai.RuntimeError{Code: "invalid_agent_failure_reason", Message: "失败分类无效"})
		return
	}
	if strings.TrimSpace(request.Signal) != "" {
		if err := h.runtime.RecordUserSignal(c.Request.Context(), userID, runID, signal, request.Note); err != nil {
			writeAIRuntimeError(c, err)
			return
		}
		result["signal"] = signal
	}
	if strings.TrimSpace(request.FailureReason) != "" {
		candidate, err := h.runtime.ClassifyFailure(c.Request.Context(), userID, runID, reason, request.Note)
		if err != nil {
			writeAIRuntimeError(c, err)
			return
		}
		result["scenario_candidate"] = candidate
	}
	if len(result) == 1 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_agent_feedback", "message": "至少提供一个有效反馈信号或失败分类"})
		return
	}
	c.JSON(http.StatusAccepted, result)
}

func (h *AIRuntimeHandler) GetRunMetrics(c *gin.Context) {
	metrics, err := h.runtime.TraceMetrics(c.Request.Context(), c.GetUint("user_id"), c.Param("id"))
	if err != nil {
		writeAIRuntimeError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"run_id": c.Param("id"), "metrics": metrics})
}

func (h *AIRuntimeHandler) DeleteRunObservability(c *gin.Context) {
	result, err := h.runtime.DeleteRunObservability(c.Request.Context(), c.GetUint("user_id"), c.Param("id"))
	if err != nil {
		writeAIRuntimeError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"deleted": result})
}

func (h *AIRuntimeHandler) DeleteUserObservability(c *gin.Context) {
	result, err := h.runtime.DeleteUserObservability(c.Request.Context(), c.GetUint("user_id"))
	if err != nil {
		writeAIRuntimeError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"deleted": result})
}

func (h *AIRuntimeHandler) Events(c *gin.Context) {
	runID := c.Param("id")
	userID := c.GetUint("user_id")
	run, err := h.runtime.GetRun(c.Request.Context(), userID, runID)
	if err != nil {
		writeAIRuntimeError(c, err)
		return
	}
	afterSeq := parseLastEventID(c.GetHeader("Last-Event-ID"))
	live, unsubscribe := h.runtime.Broker().Subscribe(runID)
	defer unsubscribe()

	c.Header("Content-Type", "text/event-stream; charset=utf-8")
	c.Header("Cache-Control", "no-cache, no-store")
	c.Header("Connection", "keep-alive")
	c.Header("X-Accel-Buffering", "no")
	c.Status(http.StatusOK)
	flusher, ok := c.Writer.(http.Flusher)
	if !ok {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "sse_unsupported", "message": "服务器不支持事件流"})
		return
	}

	history, err := h.runtime.EventsAfter(c.Request.Context(), userID, runID, afterSeq)
	if err != nil {
		return
	}
	lastSent := afterSeq
	terminalReplayed := false
	for _, event := range history {
		if err := writeSSE(c.Writer, ai.RunEvent{
			RunID: event.RunID, Seq: event.Seq, Type: event.Type,
			Timestamp: event.CreatedAt, Payload: json.RawMessage(event.Payload),
		}); err != nil {
			h.cancelDisconnectedRun(userID, runID)
			return
		}
		lastSent = event.Seq
		terminalReplayed = isTerminalAIEvent(event.Type)
	}
	flusher.Flush()
	if terminalReplayed || isTerminalAIRunState(run.State) {
		return
	}

	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()
	for {
		select {
		case <-c.Request.Context().Done():
			h.cancelDisconnectedRun(userID, runID)
			return
		case event, open := <-live:
			if !open {
				return
			}
			if event.Seq <= lastSent {
				continue
			}
			if err := writeSSE(c.Writer, event); err != nil {
				h.cancelDisconnectedRun(userID, runID)
				return
			}
			lastSent = event.Seq
			flusher.Flush()
			if isTerminalAIEvent(event.Type) {
				return
			}
		case timestamp := <-heartbeat.C:
			payload, _ := json.Marshal(gin.H{"run_id": runID, "type": "heartbeat", "timestamp": timestamp})
			if _, err := fmt.Fprintf(c.Writer, "event: heartbeat\ndata: %s\n\n", payload); err != nil {
				h.cancelDisconnectedRun(userID, runID)
				return
			}
			flusher.Flush()
		}
	}
}

// cancelDisconnectedRun 使用独立短 Context 更新状态；HTTP Context 在客户端断开时已经取消。
// Runtime 随后会取消同一个 Python 请求 Context，实现从客户端到模型的取消传播。
func (h *AIRuntimeHandler) cancelDisconnectedRun(userID uint, runID string) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, _ = h.runtime.Cancel(ctx, userID, runID)
}

func writeSSE(writer http.ResponseWriter, event ai.RunEvent) error {
	payload, err := json.Marshal(event)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(writer, "id: %d\nevent: %s\ndata: %s\n\n", event.Seq, event.Type, payload)
	return err
}

func parseLastEventID(value string) int64 {
	value = strings.TrimSpace(value)
	if index := strings.LastIndexByte(value, ':'); index >= 0 {
		value = value[index+1:]
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil || parsed < 0 {
		return 0
	}
	return parsed
}

func isTerminalAIEvent(eventType string) bool {
	return eventType == "run.completed" || eventType == "run.failed" || eventType == "run.cancelled"
}

func isTerminalAIRunState(state string) bool {
	switch state {
	case models.AIRunStateCompleted, models.AIRunStateFailed, models.AIRunStateCancelled, models.AIRunStateExpired:
		return true
	default:
		return false
	}
}

type createAIConversationRequest struct {
	Title string `json:"title"`
}

func (h *AIRuntimeHandler) CreateConversation(c *gin.Context) {
	var request createAIConversationRequest
	if err := decodeStrictJSON(c, &request, 8<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request", "message": "请求格式错误"})
		return
	}
	request.Title = strings.TrimSpace(request.Title)
	if len([]rune(request.Title)) > 80 {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"code": "conversation_title_too_long", "message": "会话标题过长"})
		return
	}
	conversation := models.AIConversation{ID: uuid.NewString(), UserID: c.GetUint("user_id"), Title: request.Title}
	if err := h.db.WithContext(c.Request.Context()).Create(&conversation).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ai_conversation_create_failed", "message": "创建会话失败"})
		return
	}
	c.JSON(http.StatusCreated, gin.H{"conversation": conversation})
}

type aiConversationListItem struct {
	ID                 string    `json:"id"`
	Title              string    `json:"title"`
	LastMessagePreview string    `json:"last_message_preview"`
	CreatedAt          time.Time `json:"created_at"`
	UpdatedAt          time.Time `json:"updated_at"`
}

func (h *AIRuntimeHandler) ListConversations(c *gin.Context) {
	var conversations []aiConversationListItem
	if err := h.db.WithContext(c.Request.Context()).
		Table("ai_conversations c").
		Select("c.id, c.title, c.created_at, c.updated_at, COALESCE((SELECT m.content FROM ai_conversation_messages m WHERE m.conversation_id = c.id ORDER BY m.created_at DESC, m.id DESC LIMIT 1), '') AS last_message_preview").
		Where("c.user_id = ?", c.GetUint("user_id")).
		Order("c.updated_at DESC").
		Limit(100).
		Find(&conversations).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ai_conversation_list_failed", "message": "读取会话失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"conversations": conversations})
}

func (h *AIRuntimeHandler) GetConversation(c *gin.Context) {
	var conversation models.AIConversation
	if err := h.db.WithContext(c.Request.Context()).Where("id = ? AND user_id = ?", c.Param("id"), c.GetUint("user_id")).First(&conversation).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"code": "ai_conversation_not_found", "message": "会话不存在"})
		return
	}
	var messages []models.AIConversationMessage
	if err := h.db.WithContext(c.Request.Context()).Where("conversation_id = ?", conversation.ID).Order("created_at ASC, id ASC").Find(&messages).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ai_conversation_read_failed", "message": "读取会话失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"conversation": conversation, "messages": messages})
}

func (h *AIRuntimeHandler) DeleteConversation(c *gin.Context) {
	if !requireEmptyKnowledgeActionBody(c) {
		return
	}
	conversationID := c.Param("id")
	userID := c.GetUint("user_id")
	var runs []models.AIRun
	if err := h.db.Where("conversation_id = ? AND user_id = ?", conversationID, userID).Find(&runs).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ai_conversation_delete_failed", "message": "删除会话失败"})
		return
	}
	var conversationCount int64
	if err := h.db.Model(&models.AIConversation{}).Where("id = ? AND user_id = ?", conversationID, userID).Count(&conversationCount).Error; err != nil || conversationCount != 1 {
		c.JSON(http.StatusNotFound, gin.H{"code": "ai_conversation_not_found", "message": "会话不存在"})
		return
	}
	for _, run := range runs {
		_, _ = h.runtime.Cancel(c.Request.Context(), userID, run.ID)
	}
	runIDs := runIDsFromRuns(runs)
	if len(runIDs) > 0 {
		deadline := time.Now().Add(2 * time.Second)
		for {
			var unsettled int64
			if err := h.db.Model(&models.AIBudgetReservation{}).
				Where("run_id IN ? AND status = ?", runIDs, "reserved").Count(&unsettled).Error; err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"code": "ai_conversation_delete_failed", "message": "删除会话失败"})
				return
			}
			if unsettled == 0 {
				break
			}
			if time.Now().After(deadline) {
				c.JSON(http.StatusConflict, gin.H{"code": "ai_run_settlement_pending", "message": "请求正在结算，请稍后重试删除"})
				return
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	err := h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		if len(runIDs) > 0 {
			for _, runID := range runIDs {
				// 保留 user_id、created_at 和消耗状态用于滚动限额；以随机 ID 解除与已删除 Run 的关联。
				if err := tx.Model(&models.AIQuotaEntry{}).Where("run_id = ?", runID).
					Update("run_id", uuid.NewString()).Error; err != nil {
					return err
				}
			}
			for _, target := range []interface{}{&models.AIEvent{}, &models.AIToolCall{}, &models.AIBudgetReservation{}, &models.AIUsageRecord{}} {
				if err := tx.Where("run_id IN ?", runIDs).Delete(target).Error; err != nil {
					return err
				}
			}
		}
		if err := tx.Where("conversation_id = ?", conversationID).Delete(&models.AIConversationMessage{}).Error; err != nil {
			return err
		}
		if err := tx.Where("conversation_id = ? AND user_id = ?", conversationID, userID).Delete(&models.AIRun{}).Error; err != nil {
			return err
		}
		return tx.Where("id = ? AND user_id = ?", conversationID, userID).Delete(&models.AIConversation{}).Error
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ai_conversation_delete_failed", "message": "删除会话失败"})
		return
	}
	c.Status(http.StatusNoContent)
}

func runIDsFromRuns(runs []models.AIRun) []string {
	result := make([]string, len(runs))
	for index, run := range runs {
		result[index] = run.ID
	}
	return result
}

func writeAIRuntimeError(c *gin.Context, err error) {
	var runtimeErr *ai.RuntimeError
	if errors.As(err, &runtimeErr) {
		status := http.StatusUnprocessableEntity
		switch runtimeErr.Code {
		case "authentication_required":
			status = http.StatusUnauthorized
		case "ai_run_not_found", "ai_conversation_not_found":
			status = http.StatusNotFound
		case "ai_quota_exceeded":
			status = http.StatusTooManyRequests
		case "ai_budget_exceeded":
			status = http.StatusPaymentRequired
		case "idempotency_key_conflict":
			status = http.StatusConflict
		case "ai_run_not_waiting_consent", "ai_run_expired", "ai_run_consent_scope_mismatch", "ai_run_consent_conflict":
			status = http.StatusConflict
		case "invalid_client_request_id", "invalid_conversation_id", "invalid_run_id", "invalid_run_consent":
			status = http.StatusBadRequest
		case "invalid_agent_user_signal", "invalid_agent_failure_reason", "invalid_agent_feedback":
			status = http.StatusBadRequest
		}
		c.JSON(status, gin.H{"code": runtimeErr.Code, "message": runtimeErr.Message, "retryable": runtimeErr.Retryable})
		return
	}
	if errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusNotFound, gin.H{"code": "ai_not_found", "message": "资源不存在"})
		return
	}
	c.JSON(http.StatusInternalServerError, gin.H{"code": "ai_internal_error", "message": "AI 服务暂不可用"})
}
