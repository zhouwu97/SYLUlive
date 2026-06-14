package handlers

import (
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const (
	defaultMessagePageSize = 30
	maxMessagePageSize     = 100
	maxMessageLength       = 2000
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
	if err := h.db.Where("user1_id = ? OR user2_id = ?", userID, userID).
		Preload("User1").Preload("User2").
		Order("last_message_at DESC").Find(&conversations).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取会话列表失败"})
		return
	}

	// 获取每个会话的未读消息数
	type ConversationWithUnread struct {
		models.Conversation
		UnreadCount int64           `json:"unread_count"`
		LastMessage *models.Message `json:"last_message"`
	}

	result := make([]ConversationWithUnread, len(conversations))
	for i, conv := range conversations {
		if conv.LastMessageAt.IsZero() {
			conv.LastMessageAt = conv.CreatedAt
		}
		result[i] = ConversationWithUnread{Conversation: conv}
		h.db.Model(&models.Message{}).
			Where("conversation_id = ? AND sender_id != ? AND read_at IS NULL", conv.ID, userID).
			Count(&result[i].UnreadCount)
		var lastMessage models.Message
		err := h.db.Where("conversation_id = ?", conv.ID).
			Preload("Sender").Preload("File").
			Order("id DESC").First(&lastMessage).Error
		if err == nil {
			result[i].LastMessage = &lastMessage
		} else if !errors.Is(err, gorm.ErrRecordNotFound) {
			log.Printf("[DB_WARN] Failed to load last message for conversation %d: %v", conv.ID, err)
		}
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

	limit := parseMessageLimit(c.Query("limit"))
	query := h.db.Where("conversation_id = ?", convID)
	if beforeID, err := strconv.ParseUint(c.Query("before_id"), 10, 64); err == nil && beforeID > 0 {
		query = query.Where("id < ?", beforeID)
	}

	var messages []models.Message
	if err := query.
		Preload("Sender").Preload("File").
		Order("id DESC").Limit(limit).Find(&messages).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取消息列表失败"})
		return
	}
	for left, right := 0, len(messages)-1; left < right; left, right = left+1, right-1 {
		messages[left], messages[right] = messages[right], messages[left]
	}

	c.JSON(http.StatusOK, messages)
}

func parseMessageLimit(raw string) int {
	limit, err := strconv.Atoi(raw)
	if err != nil || limit <= 0 {
		return defaultMessagePageSize
	}
	if limit > maxMessagePageSize {
		return maxMessagePageSize
	}
	return limit
}

// SendMessageInput 发送消息输入
type SendMessageInput struct {
	Content string `json:"content"`
	FileID  *uint  `json:"file_id"`
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

	input.Content = strings.TrimSpace(input.Content)
	if input.Content == "" && input.FileID == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "消息内容不能为空"})
		return
	}
	if utf8.RuneCountInString(input.Content) > maxMessageLength {
		c.JSON(http.StatusBadRequest, gin.H{"error": "消息内容不能超过2000个字符"})
		return
	}

	var targetUser models.User
	if err := h.db.Select("id").First(&targetUser, uint(targetUserID)).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "目标用户不存在"})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "查询目标用户失败"})
		}
		return
	}

	if input.FileID != nil {
		var file models.File
		if err := h.db.First(&file, *input.FileID).Error; err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "图片文件不存在"})
			return
		}
		if !strings.HasPrefix(file.MimeType, "image/") {
			c.JSON(http.StatusBadRequest, gin.H{"error": "私信附件必须是图片"})
			return
		}
	}

	currentUserID := userID.(uint)
	user1ID, user2ID := currentUserID, uint(targetUserID)
	if user1ID > user2ID {
		user1ID, user2ID = user2ID, user1ID
	}

	var message models.Message
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		var conv models.Conversation
		if err := tx.Where("user1_id = ? AND user2_id = ?", user1ID, user2ID).
			First(&conv).Error; err != nil {
			if !errors.Is(err, gorm.ErrRecordNotFound) {
				return err
			}
			conv = models.Conversation{User1ID: user1ID, User2ID: user2ID}
			if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&conv).Error; err != nil {
				return err
			}
			if err := tx.Where("user1_id = ? AND user2_id = ?", user1ID, user2ID).
				First(&conv).Error; err != nil {
				return err
			}
		}

		message = models.Message{
			ConversationID: conv.ID,
			SenderID:       currentUserID,
			Content:        input.Content,
			FileID:         input.FileID,
		}
		if err := tx.Create(&message).Error; err != nil {
			return err
		}
		return tx.Model(&conv).Update("last_message_at", message.CreatedAt).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "发送消息失败"})
		return
	}

	if err := h.db.Preload("Sender").Preload("File").First(&message, message.ID).Error; err != nil {
		log.Printf("[DB_WARN] Failed to re-fetch message with sender/file after create: %v", err)
	}
	c.JSON(http.StatusCreated, message)
}

// MarkRead marks all incoming messages in a conversation as read.
func (h *MessageHandler) MarkRead(c *gin.Context) {
	userID, _ := c.Get("user_id")
	convID, ok := h.authorizedConversationID(c, userID.(uint))
	if !ok {
		return
	}

	now := time.Now()
	if err := h.db.Model(&models.Message{}).
		Where("conversation_id = ? AND sender_id != ? AND read_at IS NULL", convID, userID).
		Update("read_at", now).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "标记已读失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已标记为已读"})
}

// GetUnreadCount returns the total number of unread private messages.
func (h *MessageHandler) GetUnreadCount(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var count int64
	if err := h.db.Model(&models.Message{}).
		Joins("JOIN conversations ON conversations.id = messages.conversation_id").
		Where("(conversations.user1_id = ? OR conversations.user2_id = ?) AND messages.sender_id != ? AND messages.read_at IS NULL",
			userID, userID, userID).
		Count(&count).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取未读数量失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"count": count})
}

func (h *MessageHandler) authorizedConversationID(c *gin.Context, userID uint) (uint, bool) {
	convID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的会话ID"})
		return 0, false
	}
	var conv models.Conversation
	if err := h.db.First(&conv, convID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "会话不存在"})
		return 0, false
	}
	if conv.User1ID != userID && conv.User2ID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		return 0, false
	}
	return uint(convID), true
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
	if err := h.db.Delete(&conv).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "会话已删除"})
}
