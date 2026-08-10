package handlers

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// FeedEventHandler 处理 /api/feed/events 下的行为采集接口（FEED-2）。
type FeedEventHandler struct {
	db    *gorm.DB
	event *services.FeedEventService
}

func NewFeedEventHandler(db *gorm.DB) *FeedEventHandler {
	return &FeedEventHandler{db: db, event: services.NewFeedEventService(db)}
}

type feedEventItem struct {
	Type      string `json:"type" binding:"required"` // impression / open / dwell
	PostID    uint   `json:"post_id" binding:"required"`
	Position  int    `json:"position"`
	VisibleMS int    `json:"visible_ms"`
	DwellMS   int    `json:"dwell_ms"`
}

type feedEventBatchRequest struct {
	FeedSessionID    string          `json:"feed_session_id" binding:"required"`
	FeedKind         string          `json:"feed_kind" binding:"required"`
	AlgorithmVersion string          `json:"algorithm_version"`
	Events           []feedEventItem `json:"events" binding:"required"`
}

// RecordEventsBatch  POST /api/feed/events/batch
//
//	全部事件幂等：
//	- impression：upsert，visible_ms 取最大；
//	- open：opened_at 取最早非空值；
//	- dwell：dwell_ms 取最大（禁止累加）。
func (h *FeedEventHandler) RecordEventsBatch(c *gin.Context) {
	rawUserID, exists := c.Get("user_id")
	userID, ok := rawUserID.(uint)
	if !exists || !ok || userID == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录"})
		return
	}
	var req feedEventBatchRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效"})
		return
	}
	if !models.IsValidFeedKind(req.FeedKind) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的 feed_kind"})
		return
	}
	if len(req.Events) > 500 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "单次事件数不能超过 500"})
		return
	}

	events := make([]services.FeedEvent, 0, len(req.Events))
	for _, item := range req.Events {
		evType := models.FeedEventType(item.Type)
		switch evType {
		case models.FeedEventImpression:
			if item.Position < 0 || item.VisibleMS < 0 {
				c.JSON(http.StatusBadRequest, gin.H{"error": "impression 参数无效"})
				return
			}
		case models.FeedEventOpen:
			// open 不携带数值字段
		case models.FeedEventDwell:
			if item.DwellMS < 0 {
				c.JSON(http.StatusBadRequest, gin.H{"error": "dwell 参数无效"})
				return
			}
		default:
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效的事件类型"})
			return
		}
		events = append(events, services.FeedEvent{
			Type:      evType,
			PostID:    item.PostID,
			Position:  item.Position,
			VisibleMS: item.VisibleMS,
			DwellMS:   item.DwellMS,
		})
	}

	if err := h.event.RecordEvents(userID, req.FeedSessionID, req.FeedKind, req.AlgorithmVersion, events); err != nil {
		if errors.Is(err, services.ErrInvalidFeedEvent) {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "recorded": len(events)})
}
