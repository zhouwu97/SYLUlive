package handlers

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"xiaoyuan/internal/models"
)

// MessageHandler 私信处理器
type MessageHandler struct {
	db *gorm.DB
}

// NewMessageHandler 创建私信处理器
func NewMessageHandler(db *gorm.DB) *MessageHandler {
	return &MessageHandler{db: db}
}

// GetConversations 获取会话列表
func (h *MessageHandler) GetConversations(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var conversations []models.Conversation
	h.db.Where("user1_id = ? OR user2_id = ?", userID, userID).
		Preload("User1").Preload("User2").
		Order("last_message_at DESC").Find(&conversations)

	// 获取每个会话的未读消息数
	type ConversationWithUnread struct {
		models.Conversation
		UnreadCount int64 `json:"unread_count"`
	}

	result := make([]ConversationWithUnread, len(conversations))
	for i, conv := range conversations {
		result[i] = ConversationWithUnread{Conversation: conv}
		h.db.Model(&models.Message{}).
			Where("conversation_id = ? AND sender_id != ? AND read_at IS NULL", conv.ID, userID).
			Count(&result[i].UnreadCount)
	}

	c.JSON(http.StatusOK, result)
}

// GetMessages 获取会话消息
func (h *MessageHandler) GetMessages(c *gin.Context) {
	userID, _ := c.Get("user_id")
	convIDStr := c.Param("id")
	convID, err := strconv.ParseUint(convIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的会话ID"})
		return
	}

	// 检查用户是否有权访问此会话
	var conv models.Conversation
	if err := h.db.First(&conv, convID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "会话不存在"})
		return
	}
	if conv.User1ID != userID.(uint) && conv.User2ID != userID.(uint) {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		return
	}

	var messages []models.Message
	h.db.Where("conversation_id = ?", convID).
		Preload("Sender").Preload("File").
		Order("created_at ASC").Find(&messages)

	// 标记消息为已读
	h.db.Model(&models.Message{}).
		Where("conversation_id = ? AND sender_id != ?", convID, userID).
		Update("read_at", gorm.Expr("NOW()"))

	c.JSON(http.StatusOK, messages)
}

// SendMessageInput 发送消息输入
type SendMessageInput struct {
	Content string `json:"content"`
	FileID  *uint   `json:"file_id"`
}

// Send 发送消息
func (h *MessageHandler) Send(c *gin.Context) {
	userID, _ := c.Get("user_id")
	targetUserIDStr := c.Param("user_id")
	targetUserID, err := strconv.ParseUint(targetUserIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})
		return
	}

	// 不能给自己发消息
	if uint(targetUserID) == userID.(uint) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不能给自己发消息"})
		return
	}

	var input SendMessageInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 查找或创建会话
	var conv models.Conversation
	h.db.Where("(user1_id = ? AND user2_id = ?) OR (user1_id = ? AND user2_id = ?)",
		userID, targetUserID, targetUserID, userID).FirstOrCreate(&conv, models.Conversation{
		User1ID: uint(userID.(uint)),
		User2ID: uint(targetUserID),
	})

	message := models.Message{
		ConversationID: conv.ID,
		SenderID:       userID.(uint),
		Content:        input.Content,
		FileID:         input.FileID,
	}

	if err := h.db.Create(&message).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "发送消息失败"})
		return
	}

	// 更新会话最后消息时间
	h.db.Model(&conv).Update("last_message_at", message.CreatedAt)

	h.db.Preload("Sender").Preload("File").First(&message, message.ID)
	c.JSON(http.StatusCreated, message)
}

// DeleteConversation 删除会话
func (h *MessageHandler) DeleteConversation(c *gin.Context) {
	userID, _ := c.Get("user_id")
	convIDStr := c.Param("id")
	convID, err := strconv.ParseUint(convIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的会话ID"})
		return
	}

	var conv models.Conversation
	if err := h.db.First(&conv, convID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "会话不存在"})
		return
	}
	if conv.User1ID != userID.(uint) && conv.User2ID != userID.(uint) {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		return
	}

	h.db.Where("conversation_id = ?", convID).Delete(&models.Message{})
	h.db.Delete(&conv)
	c.JSON(http.StatusOK, gin.H{"message": "会话已删除"})
}