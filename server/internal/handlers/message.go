package handlers

import (
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

const (
	defaultMessagePageSize = 30
	maxMessagePageSize     = 100
	maxMessageLength       = 2000
	maxPairMessagesPerMin  = 5
)

// MessageHandler 私信处理器
type MessageHandler struct {
	db          *gorm.DB
	notifier    messageNotifier
	rateLimiter *messageRateLimiter
}

type messageNotifier interface {
	Notify(userID uint, title, content string, extras map[string]interface{}) error
}

// NewMessageHandler 创建私信处理器
func NewMessageHandler(db *gorm.DB, notifiers ...messageNotifier) *MessageHandler {
	var notifier messageNotifier
	if len(notifiers) > 0 {
		notifier = notifiers[0]
	}
	return &MessageHandler{
		db:          db,
		notifier:    notifier,
		rateLimiter: newMessageRateLimiter(),
	}
}

var _ messageNotifier = (*services.NotificationService)(nil)

type messageRateLimiter struct {
	mu   sync.Mutex
	hits map[string][]time.Time
}

func newMessageRateLimiter() *messageRateLimiter {
	return &messageRateLimiter{hits: make(map[string][]time.Time)}
}

func (l *messageRateLimiter) allow(senderID, targetID uint, now time.Time) bool {
	key := fmt.Sprintf("%d:%d", senderID, targetID)
	windowStart := now.Add(-time.Minute)

	l.mu.Lock()
	defer l.mu.Unlock()

	recent := l.hits[key][:0]
	for _, hit := range l.hits[key] {
		if hit.After(windowStart) {
			recent = append(recent, hit)
		}
	}
	if len(recent) >= maxPairMessagesPerMin {
		l.hits[key] = recent
		return false
	}
	recent = append(recent, now)
	l.hits[key] = recent
	return true
}

// GetConversations 获取会话列表
func (h *MessageHandler) GetConversations(c *gin.Context) {
	userID, _ := c.Get("user_id")
	currentUserID := userID.(uint)

	var conversations []models.Conversation
	if err := h.db.Where("user1_id = ? OR user2_id = ?", currentUserID, currentUserID).
		Order("last_message_at DESC, id DESC").Find(&conversations).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取会话列表失败"})
		return
	}

	type userSummary struct {
		ID       uint   `json:"id"`
		Nickname string `json:"nickname"`
		Avatar   string `json:"avatar"`
	}
	type messageSummary struct {
		ID             uint         `json:"id"`
		ConversationID uint         `json:"conversation_id"`
		SenderID       uint         `json:"sender_id"`
		Content        string       `json:"content"`
		FileID         *uint        `json:"file_id"`
		CreatedAt      time.Time    `json:"created_at"`
		ReadAt         *time.Time   `json:"read_at"`
		File           *models.File `json:"file"`
	}
	type conversationResponse struct {
		ID            uint            `json:"id"`
		User1ID       uint            `json:"user1_id"`
		User2ID       uint            `json:"user2_id"`
		LastMessageAt time.Time       `json:"last_message_at"`
		CreatedAt     time.Time       `json:"created_at"`
		User1         *userSummary    `json:"user1"`
		User2         *userSummary    `json:"user2"`
		UnreadCount   int64           `json:"unread_count"`
		LastMessage   *messageSummary `json:"last_message"`
	}

	conversationIDs := make([]uint, 0, len(conversations))
	userIDs := make([]uint, 0, len(conversations)*2)
	for _, conv := range conversations {
		conversationIDs = append(conversationIDs, conv.ID)
		userIDs = append(userIDs, conv.User1ID, conv.User2ID)
	}

	userMap := make(map[uint]userSummary)
	if len(userIDs) > 0 {
		var users []models.User
		if err := h.db.Select("id", "nickname", "avatar").Where("id IN ?", userIDs).Find(&users).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取会话用户失败"})
			return
		}
		for _, user := range users {
			userMap[user.ID] = userSummary{ID: user.ID, Nickname: user.Nickname, Avatar: user.Avatar}
		}
	}

	unreadMap := make(map[uint]int64)
	lastMessageMap := make(map[uint]messageSummary)
	if len(conversationIDs) > 0 {
		type unreadRow struct {
			ConversationID uint
			Count          int64
		}
		var unreadRows []unreadRow
		if err := h.db.Model(&models.Message{}).
			Select("conversation_id, COUNT(*) AS count").
			Where("conversation_id IN ? AND sender_id != ? AND read_at IS NULL", conversationIDs, currentUserID).
			Group("conversation_id").
			Scan(&unreadRows).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取未读数量失败"})
			return
		}
		for _, row := range unreadRows {
			unreadMap[row.ConversationID] = row.Count
		}

		type lastRow struct {
			ConversationID uint
			MessageID      uint
		}
		var lastRows []lastRow
		if err := h.db.Model(&models.Message{}).
			Select("conversation_id, MAX(id) AS message_id").
			Where("conversation_id IN ?", conversationIDs).
			Group("conversation_id").
			Scan(&lastRows).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取最后消息失败"})
			return
		}
		messageIDs := make([]uint, 0, len(lastRows))
		for _, row := range lastRows {
			messageIDs = append(messageIDs, row.MessageID)
		}
		if len(messageIDs) > 0 {
			var messages []models.Message
			if err := h.db.Where("id IN ?", messageIDs).Preload("File").Find(&messages).Error; err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "获取最后消息失败"})
				return
			}
			for _, message := range messages {
				lastMessageMap[message.ConversationID] = messageSummary{
					ID:             message.ID,
					ConversationID: message.ConversationID,
					SenderID:       message.SenderID,
					Content:        message.Content,
					FileID:         message.FileID,
					CreatedAt:      message.CreatedAt,
					ReadAt:         message.ReadAt,
					File:           message.File,
				}
			}
		}
	}

	result := make([]conversationResponse, len(conversations))
	for i, conv := range conversations {
		if conv.LastMessageAt.IsZero() {
			conv.LastMessageAt = conv.CreatedAt
		}
		var user1, user2 *userSummary
		if summary, ok := userMap[conv.User1ID]; ok {
			user1 = &summary
		}
		if summary, ok := userMap[conv.User2ID]; ok {
			user2 = &summary
		}
		result[i] = conversationResponse{
			ID:            conv.ID,
			User1ID:       conv.User1ID,
			User2ID:       conv.User2ID,
			LastMessageAt: conv.LastMessageAt,
			CreatedAt:     conv.CreatedAt,
			User1:         user1,
			User2:         user2,
			UnreadCount:   unreadMap[conv.ID],
		}
		if message, ok := lastMessageMap[conv.ID]; ok {
			result[i].LastMessage = &message
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
	order := "id DESC"
	reverse := true
	if afterID, err := strconv.ParseUint(c.Query("after_id"), 10, 64); err == nil && afterID > 0 {
		query = query.Where("id > ?", afterID)
		order = "id ASC"
		reverse = false
	} else if beforeID, err := strconv.ParseUint(c.Query("before_id"), 10, 64); err == nil && beforeID > 0 {
		query = query.Where("id < ?", beforeID)
	}

	var messages []models.Message
	if err := query.
		Preload("Sender").Preload("File").
		Order(order).Limit(limit).Find(&messages).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取消息列表失败"})
		return
	}
	if reverse {
		for left, right := 0, len(messages)-1; left < right; left, right = left+1, right-1 {
			messages[left], messages[right] = messages[right], messages[left]
		}
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

	currentUserID := userID.(uint)
	targetID := uint(targetUserID)

	// 不能给自己发消息
	if targetID == currentUserID {
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
	if err := h.db.Select("id", "nickname", "avatar").First(&targetUser, targetID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "目标用户不存在"})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "查询目标用户失败"})
		}
		return
	}

	if !h.rateLimiter.allow(currentUserID, targetID, time.Now()) {
		c.JSON(http.StatusTooManyRequests, gin.H{"error": "发送太频繁，请稍后再试"})
		return
	}

	var sender models.User
	if err := h.db.Select("id", "nickname", "avatar").First(&sender, currentUserID).Error; err != nil {
		sender = models.User{ID: currentUserID, Nickname: fmt.Sprintf("用户%d", currentUserID)}
	}

	var messageFile *models.File
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
		messageFile = &file
	}

	user1ID, user2ID := currentUserID, targetID
	if user1ID > user2ID {
		user1ID, user2ID = user2ID, user1ID
	}

	var message models.Message
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		conv, err := h.getOrCreateConversation(tx, user1ID, user2ID, time.Now())
		if err != nil {
			return err
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

	message.Sender = sender
	if messageFile != nil {
		message.File = messageFile
	}
	h.pushPrivateMessage(targetID, sender, message)
	c.JSON(http.StatusCreated, message)
}

func (h *MessageHandler) getOrCreateConversation(tx *gorm.DB, user1ID, user2ID uint, now time.Time) (models.Conversation, error) {
	var conv models.Conversation
	err := tx.Where("user1_id = ? AND user2_id = ?", user1ID, user2ID).First(&conv).Error
	if err == nil {
		return conv, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return conv, err
	}

	conv = models.Conversation{User1ID: user1ID, User2ID: user2ID, LastMessageAt: now}
	createErr := tx.Create(&conv).Error
	if createErr == nil {
		return conv, nil
	}
	if readErr := tx.Where("user1_id = ? AND user2_id = ?", user1ID, user2ID).First(&conv).Error; readErr == nil {
		return conv, nil
	}
	return conv, createErr
}

func (h *MessageHandler) pushPrivateMessage(targetUserID uint, sender models.User, message models.Message) {
	if h.notifier == nil || targetUserID == sender.ID {
		return
	}
	title := sender.Nickname
	if strings.TrimSpace(title) == "" {
		title = fmt.Sprintf("用户%d", sender.ID)
	}
	content := privateMessagePreview(message)
	extras := map[string]interface{}{
		"type":            "private_message",
		"conversation_id": message.ConversationID,
		"sender_id":       sender.ID,
	}
	go func() {
		if err := h.notifier.Notify(targetUserID, title, content, extras); err != nil {
			log.Printf("[JPUSH_WARN] private message push failed user=%d conversation=%d err=%v", targetUserID, message.ConversationID, err)
		}
	}()
}

func privateMessagePreview(message models.Message) string {
	content := strings.TrimSpace(message.Content)
	if content == "" && message.FileID != nil {
		return "[图片]"
	}
	runes := []rune(content)
	if len(runes) > 50 {
		return string(runes[:50]) + "..."
	}
	return content
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

	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("conversation_id = ?", convID).Delete(&models.Message{}).Error; err != nil {
			return err
		}
		return tx.Delete(&conv).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "会话已删除"})
}
