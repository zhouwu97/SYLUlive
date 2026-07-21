package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
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
	ConversationID  string `json:"conversation_id"`
	ClientRequestID string `json:"client_request_id"`
	Message         string `json:"message"`
}

func (h *AIRuntimeHandler) CreateRun(c *gin.Context) {
	var request createAIRunRequest
	if err := decodeStrictJSON(c, &request, 16<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request", "message": "请求格式错误"})
		return
	}
	run, duplicate, err := h.runtime.CreateRun(c.Request.Context(), c.GetUint("user_id"), ai.CreateRunRequest{
		ConversationID: request.ConversationID, ClientRequestID: request.ClientRequestID, Message: request.Message,
	})
	if err != nil {
		writeAIRuntimeError(c, err)
		return
	}
	status := http.StatusAccepted
	if duplicate {
		status = http.StatusOK
	}
	c.JSON(status, gin.H{"run": run, "duplicate": duplicate})
}

func (h *AIRuntimeHandler) GetRun(c *gin.Context) {
	run, err := h.runtime.GetRun(c.Request.Context(), c.GetUint("user_id"), c.Param("id"))
	if err != nil {
		writeAIRuntimeError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"run": run})
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

func (h *AIRuntimeHandler) Events(c *gin.Context) {
	runID := c.Param("id")
	userID := c.GetUint("user_id")
	if _, err := h.runtime.GetRun(c.Request.Context(), userID, runID); err != nil {
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
			return
		}
		lastSent = event.Seq
		terminalReplayed = isTerminalAIEvent(event.Type)
	}
	flusher.Flush()
	if terminalReplayed {
		return
	}

	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()
	for {
		select {
		case <-c.Request.Context().Done():
			return
		case event, open := <-live:
			if !open {
				return
			}
			if event.Seq <= lastSent {
				continue
			}
			if err := writeSSE(c.Writer, event); err != nil {
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
				return
			}
			flusher.Flush()
		}
	}
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
		case "invalid_client_request_id", "invalid_conversation_id", "invalid_run_id":
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
