package handlers

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// NotificationHandler 通知处理器
type NotificationHandler struct {
	db *gorm.DB
}

// NewNotificationHandler 创建通知处理器
func NewNotificationHandler(db *gorm.DB) *NotificationHandler {
	return &NotificationHandler{db: db}
}

// GetUnreadCount 获取未读通知数量（红点用）
func (h *NotificationHandler) GetUnreadCount(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	var count int64
	h.db.Model(&models.Notification{}).Where("user_id = ? AND is_read = ?", uid, false).Count(&count)

	c.JSON(http.StatusOK, gin.H{
		"count": count,
	})
}

// MarkAllRead 将所有通知标记为已读
func (h *NotificationHandler) MarkAllRead(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	h.db.Model(&models.Notification{}).Where("user_id = ? AND is_read = ?", uid, false).Update("is_read", true)

	c.JSON(http.StatusOK, gin.H{"message": "已全部标记为已读"})
}

// CreateReplyNotification 创建回复通知（被 reply handler 调用）
func CreateReplyNotification(db *gorm.DB, toUserID, fromUserID, replyID, postID uint, content string) {
	if toUserID == fromUserID {
		return // 不通知自己
	}
	notification := models.Notification{
		UserID:    toUserID,
		Type:      "reply",
		Content:   content,
		RelatedID: replyID,
		PostID:    postID,
		FromUID:   fromUserID,
		IsRead:    false,
	}
	db.Create(&notification)
}
