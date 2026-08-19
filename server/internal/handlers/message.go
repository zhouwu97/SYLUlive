package handlers

import (
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"shenliyuan/internal/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

const (
	defaultMessagePageSize = 30
	maxMessagePageSize     = 100
	maxMessageLength       = 2000
	maxClientMessageIDSize = 96
	maxPairMessagesPerMin  = 50
	maxUserMessagesPerMin  = 120
)

// MessageHandler 私信处理器
type MessageHandler struct {
	db          *gorm.DB
	uploadDir   string
	notifier    messageNotifier
	rateLimiter *messageRateLimiter
	events      *messageEventBroker
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
		events:      newMessageEventBroker(),
	}
}

var _ messageNotifier = (*services.NotificationService)(nil)

// MessageFileDTO 是私信附件的最小安全响应，不暴露服务器磁盘路径。
type MessageFileDTO struct {
	ID          uint   `json:"id"`
	MimeType    string `json:"mime_type"`
	Size        int64  `json:"size"`
	DownloadURL string `json:"download_url"`
	Width       int    `json:"width"`
	Height      int    `json:"height"`
}

// PrivateMessageDTO 统一 REST、SSE 和发送响应的私信结构。
type PrivateMessageDTO struct {
	ID              uint                      `json:"id"`
	ConversationID  uint                      `json:"conversation_id"`
	SenderID        uint                      `json:"sender_id"`
	ClientMessageID *string                   `json:"client_message_id,omitempty"`
	Content         string                    `json:"content"`
	FileID          *uint                     `json:"file_id"`
	StickerID       *string                   `json:"sticker_id,omitempty"`
	CreatedAt       time.Time                 `json:"created_at"`
	ReadAt          *time.Time                `json:"read_at"`
	Sender          models.PublicUserResponse `json:"sender"`
	File            *MessageFileDTO           `json:"file"`
}

func privateMessageFileResponse(file *models.File) *MessageFileDTO {
	if file == nil || file.ID == 0 {
		return nil
	}
	return &MessageFileDTO{
		ID:          file.ID,
		MimeType:    file.MimeType,
		Size:        file.Size,
		DownloadURL: fmt.Sprintf("/api/messages/files/%d", file.ID),
		Width:       file.Width,
		Height:      file.Height,
	}
}

func privateMessageResponse(message models.Message) PrivateMessageDTO {
	return PrivateMessageDTO{
		ID:              message.ID,
		ConversationID:  message.ConversationID,
		SenderID:        message.SenderID,
		ClientMessageID: message.ClientMessageID,
		Content:         message.Content,
		FileID:          message.FileID,
		StickerID:       message.StickerID,
		CreatedAt:       message.CreatedAt,
		ReadAt:          message.ReadAt,
		Sender:          models.PublicUser(message.Sender),
		File:            privateMessageFileResponse(message.File),
	}
}

// SetUploadDir 注入公开上传目录，用于私信附件的安全磁盘解析。
func (h *MessageHandler) SetUploadDir(uploadDir string) {
	h.uploadDir = strings.TrimSpace(uploadDir)
}

type messageRateLimiter struct {
	mu            sync.Mutex
	pairHits      map[string][]time.Time
	userHits      map[uint][]time.Time
	lastCleanupAt time.Time
}

func newMessageRateLimiter() *messageRateLimiter {
	return &messageRateLimiter{
		pairHits: make(map[string][]time.Time),
		userHits: make(map[uint][]time.Time),
	}
}

func (l *messageRateLimiter) allow(senderID, targetID uint, now time.Time) bool {
	key := fmt.Sprintf("%d:%d", senderID, targetID)
	windowStart := now.Add(-time.Minute)

	l.mu.Lock()
	defer l.mu.Unlock()
	if l.lastCleanupAt.IsZero() || !now.Before(l.lastCleanupAt.Add(time.Minute)) {
		for key, hits := range l.pairHits {
			if recent := recentMessageHits(hits, windowStart); len(recent) == 0 {
				delete(l.pairHits, key)
			} else {
				l.pairHits[key] = recent
			}
		}
		for userID, hits := range l.userHits {
			if recent := recentMessageHits(hits, windowStart); len(recent) == 0 {
				delete(l.userHits, userID)
			} else {
				l.userHits[userID] = recent
			}
		}
		l.lastCleanupAt = now
	}

	pairRecent := recentMessageHits(l.pairHits[key], windowStart)
	userRecent := recentMessageHits(l.userHits[senderID], windowStart)
	if len(pairRecent) >= maxPairMessagesPerMin || len(userRecent) >= maxUserMessagesPerMin {
		l.pairHits[key] = pairRecent
		l.userHits[senderID] = userRecent
		return false
	}
	l.pairHits[key] = append(pairRecent, now)
	l.userHits[senderID] = append(userRecent, now)
	return true
}

func recentMessageHits(hits []time.Time, windowStart time.Time) []time.Time {
	recent := hits[:0]
	for _, hit := range hits {
		if hit.After(windowStart) {
			recent = append(recent, hit)
		}
	}
	return recent
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
		ID              uint            `json:"id"`
		ConversationID  uint            `json:"conversation_id"`
		SenderID        uint            `json:"sender_id"`
		ClientMessageID *string         `json:"client_message_id,omitempty"`
		Content         string          `json:"content"`
		FileID          *uint           `json:"file_id"`
		StickerID       *string         `json:"sticker_id,omitempty"`
		CreatedAt       time.Time       `json:"created_at"`
		ReadAt          *time.Time      `json:"read_at"`
		File            *MessageFileDTO `json:"file"`
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
					ID:              message.ID,
					ConversationID:  message.ConversationID,
					SenderID:        message.SenderID,
					ClientMessageID: message.ClientMessageID,
					Content:         message.Content,
					FileID:          message.FileID,
					StickerID:       message.StickerID,
					CreatedAt:       message.CreatedAt,
					ReadAt:          message.ReadAt,
					File:            privateMessageFileResponse(message.File),
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

// GetConversationWithUser 轻量查询两名用户之间是否已有会话。
// 聊天壳可以先展示，再按返回的会话 ID 增量加载消息，无需扫描整个会话列表。
func (h *MessageHandler) GetConversationWithUser(c *gin.Context) {
	currentUserID := c.GetUint("user_id")
	targetUserID, err := strconv.ParseUint(c.Param("target_user_id"), 10, 64)
	if err != nil || targetUserID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})
		return
	}
	targetID := uint(targetUserID)
	if targetID == currentUserID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不能给自己发消息"})
		return
	}

	var targetCount int64
	if err := h.db.Model(&models.User{}).Where("id = ?", targetID).Count(&targetCount).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询目标用户失败"})
		return
	}
	if targetCount == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "目标用户不存在"})
		return
	}

	user1ID, user2ID := currentUserID, targetID
	if user1ID > user2ID {
		user1ID, user2ID = user2ID, user1ID
	}
	type conversationLookup struct {
		ID            uint      `json:"id"`
		User1ID       uint      `json:"user1_id"`
		User2ID       uint      `json:"user2_id"`
		LastMessageAt time.Time `json:"last_message_at"`
		CreatedAt     time.Time `json:"created_at"`
	}
	var conversation models.Conversation
	var summary *conversationLookup
	conversationErr := h.db.Where("user1_id = ? AND user2_id = ?", user1ID, user2ID).
		First(&conversation).Error
	if conversationErr == nil {
		summary = &conversationLookup{
			ID:            conversation.ID,
			User1ID:       conversation.User1ID,
			User2ID:       conversation.User2ID,
			LastMessageAt: conversation.LastMessageAt,
			CreatedAt:     conversation.CreatedAt,
		}
	} else if !errors.Is(conversationErr, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询会话失败"})
		return
	}

	_, reason, state, stateErr := h.canSendMessage(currentUserID, targetID)
	if stateErr != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询发送状态失败"})
		return
	}
	if !state.CanSend {
		state.Reason = reason
	}
	c.JSON(http.StatusOK, gin.H{
		"conversation": summary,
		"can_send":     state.CanSend,
		"reason":       state.Reason,
	})
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
	if aroundID, err := strconv.ParseUint(c.Query("around_id"), 10, 64); err == nil && aroundID > 0 {
		query = query.Where("id <= ?", aroundID)
	} else if afterID, err := strconv.ParseUint(c.Query("after_id"), 10, 64); err == nil && afterID > 0 {
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

	responses := make([]PrivateMessageDTO, 0, len(messages))
	for _, message := range messages {
		responses = append(responses, privateMessageResponse(message))
	}
	c.JSON(http.StatusOK, responses)
}

// ServePrivateFile 只允许当前用户所属会话中的消息附件被读取。
// 无权限和不存在统一返回 404，避免确认私信附件是否存在；
// 内部记录细分失败原因，便于定位坏图属于权限/数据库/路径/磁盘哪一类。
func (h *MessageHandler) ServePrivateFile(c *gin.Context) {
	requestID := fmt.Sprintf("%d", time.Now().UnixNano())
	userID := c.GetUint("user_id")
	fileIDRaw := c.Param("file_id")
	notFound := func(reason string) {
		log.Printf("[PM_MEDIA] serve_private_file reason=%s user_id=%d file_id=%s request_id=%s",
			reason, userID, fileIDRaw, requestID)
		c.Status(http.StatusNotFound)
		c.Writer.WriteHeaderNow()
	}

	fileID, err := strconv.ParseUint(fileIDRaw, 10, 64)
	if err != nil || fileID == 0 {
		notFound("parse_failed")
		return
	}

	var file models.File
	err = h.db.Model(&models.File{}).Where("files.id = ?", fileID).First(&file).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		notFound("record_missing")
		return
	}
	if err != nil {
		notFound("db_failed")
		return
	}

	// 单独校验当前用户是否属于引用该附件的任一会话，与“记录不存在”区分开，
	// 但客户端同样只会看到 404。
	var accessCount int64
	if err := h.db.Model(&models.Message{}).
		Joins("JOIN conversations AS conv ON conv.id = messages.conversation_id").
		Where("messages.file_id = ? AND (conv.user1_id = ? OR conv.user2_id = ?)",
			fileID, userID, userID).
		Count(&accessCount).Error; err != nil {
		notFound("access_check_db_failed")
		return
	}
	if accessCount == 0 {
		notFound("no_message_access")
		return
	}

	fullPath, err := services.ResolveUploadPath(h.uploadDir, file.Path)
	if err != nil {
		notFound("invalid_stored_path")
		return
	}
	if _, err := os.Stat(fullPath); err != nil {
		notFound("disk_missing")
		return
	}
	c.Header("Content-Type", file.MimeType)
	c.Header("Cache-Control", "private, no-store")
	c.Header("X-Content-Type-Options", "nosniff")
	c.File(fullPath)
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
	Content         string  `json:"content"`
	FileID          *uint   `json:"file_id"`
	StickerID       *string `json:"sticker_id"`
	ClientMessageID *string `json:"client_message_id"`
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
	if input.Content == "" && input.FileID == nil && input.StickerID == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "消息内容不能为空"})
		return
	}
	if input.StickerID != nil {
		stickerID := strings.TrimSpace(*input.StickerID)
		if !IsValidStickerID(stickerID) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "表情不存在"})
			return
		}
		if input.FileID != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "表情消息不能同时包含图片"})
			return
		}
		input.StickerID = &stickerID
		if input.Content == "" {
			// 旧客户端不认识 sticker_id，纯表情仍保留可读的文本回退。
			input.Content = stickerFallbackText
		}
	}
	if utf8.RuneCountInString(input.Content) > maxMessageLength {
		c.JSON(http.StatusBadRequest, gin.H{"error": "消息内容不能超过2000个字符"})
		return
	}
	if input.ClientMessageID != nil {
		clientMessageID := strings.TrimSpace(*input.ClientMessageID)
		if clientMessageID == "" || len(clientMessageID) > maxClientMessageIDSize {
			c.JSON(http.StatusBadRequest, gin.H{"error": "客户端消息ID无效"})
			return
		}
		input.ClientMessageID = &clientMessageID
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

	if input.ClientMessageID != nil {
		existing, found, lookupErr := h.findIdempotentMessage(
			currentUserID,
			targetID,
			*input.ClientMessageID,
		)
		if lookupErr != nil {
			if errors.Is(lookupErr, errClientMessageTargetMismatch) {
				c.JSON(http.StatusConflict, gin.H{"error": "客户端消息ID已用于其他会话"})
			} else {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "查询消息发送状态失败"})
			}
			return
		}
		if found {
			c.Header("X-Idempotent-Replay", "true")
			c.JSON(http.StatusCreated, privateMessageResponse(existing))
			return
		}
	}

	// 陌生人私信限制：
	// current 已经给 target 发过且 target 未关注/未回复 → 拒绝
	allow, reason, _, canErr := h.canSendMessage(currentUserID, targetID)
	if canErr != nil {
		log.Printf("[PM_LIMIT] canSendMessage unexpected error current=%d target=%d err=%v", currentUserID, targetID, canErr)
		c.JSON(http.StatusServiceUnavailable, gin.H{
			"error": "暂时无法确认私信发送权限，请稍后重试",
			"code":  "message_send_state_unavailable",
		})
		return
	}
	if !allow {
		c.JSON(http.StatusForbidden, gin.H{
			"error": "对方未关注你或回复你之前，只能发送 1 条消息，请等待对方回应。",
			"code":  "message_requires_reply_or_follow",
			// 兼容旧客户端读取 reason 字段
			"reason": reason,
		})
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
		var grantCount int64
		if err := h.db.Model(&models.FileUploadGrant{}).
			Where("file_id = ? AND user_id = ?", file.ID, currentUserID).
			Count(&grantCount).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "校验图片所有权失败"})
			return
		}
		var emojiAssetCount int64
		if file.UploaderID != currentUserID && grantCount == 0 {
			if err := h.db.Model(&models.UserEmojiAsset{}).
				Where("file_id = ? AND user_id = ?", file.ID, currentUserID).
				Count(&emojiAssetCount).Error; err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "校验图片所有权失败"})
				return
			}
		}
		if file.UploaderID != currentUserID && grantCount == 0 && emojiAssetCount == 0 {
			c.JSON(http.StatusForbidden, gin.H{"error": "无权发送该图片"})
			return
		}
		messageFile = &file
	}

	// 仅有效且有发送权限的请求才消耗限流额度。
	if !h.rateLimiter.allow(currentUserID, targetID, time.Now()) {
		c.JSON(http.StatusTooManyRequests, gin.H{"error": "发送太频繁，请稍后再试"})
		return
	}

	user1ID, user2ID := currentUserID, targetID
	if user1ID > user2ID {
		user1ID, user2ID = user2ID, user1ID
	}

	var message models.Message
	var conversation models.Conversation
	createErr := h.db.Transaction(func(tx *gorm.DB) error {
		conv, err := services.GetOrCreateConversation(tx, user1ID, user2ID, time.Now())
		if err != nil {
			return err
		}
		conversation = conv

		message = models.Message{
			ConversationID:  conv.ID,
			SenderID:        currentUserID,
			ClientMessageID: input.ClientMessageID,
			Content:         input.Content,
			FileID:          input.FileID,
			StickerID:       input.StickerID,
		}
		if err := tx.Create(&message).Error; err != nil {
			return err
		}
		if input.FileID != nil {
			if err := services.ClaimPrivateMessageFile(tx, *input.FileID); err != nil {
				return err
			}
		}
		return tx.Model(&conv).Update("last_message_at", message.CreatedAt).Error
	})
	if createErr != nil {
		// 两个相同请求并发通过前置查询时，唯一索引决定最终结果。
		if input.ClientMessageID != nil {
			existing, found, lookupErr := h.findIdempotentMessage(
				currentUserID,
				targetID,
				*input.ClientMessageID,
			)
			if lookupErr == nil && found {
				c.Header("X-Idempotent-Replay", "true")
				c.JSON(http.StatusCreated, privateMessageResponse(existing))
				return
			}
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "发送消息失败"})
		return
	}

	message.Sender = sender
	if messageFile != nil {
		message.File = messageFile
	}
	response := privateMessageResponse(message)
	h.events.publish(
		[]uint{conversation.User1ID, conversation.User2ID},
		privateMessageEvent{
			Type:           "message.created",
			ConversationID: message.ConversationID,
			Message:        &response,
		},
	)
	h.pushPrivateMessage(targetID, sender, message)
	c.JSON(http.StatusCreated, response)
}

var errClientMessageTargetMismatch = errors.New("client message id target mismatch")

func (h *MessageHandler) findIdempotentMessage(
	senderID uint,
	targetID uint,
	clientMessageID string,
) (models.Message, bool, error) {
	var message models.Message
	err := h.db.Where("sender_id = ? AND client_message_id = ?", senderID, clientMessageID).
		Preload("Sender").Preload("File").First(&message).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return models.Message{}, false, nil
	}
	if err != nil {
		return models.Message{}, false, err
	}

	var conversation models.Conversation
	if err := h.db.First(&conversation, message.ConversationID).Error; err != nil {
		return models.Message{}, false, err
	}
	isExpectedPair := (conversation.User1ID == senderID && conversation.User2ID == targetID) ||
		(conversation.User1ID == targetID && conversation.User2ID == senderID)
	if !isExpectedPair {
		return models.Message{}, false, errClientMessageTargetMismatch
	}
	return message, true, nil
}

// canSendMessage 陌生人私信限制
//
// 允许发送，如果满足任意一个：
//  1. target 已关注 current（UserFollow: follower=target, following=current）
//  2. target 曾经给 current 发过消息
//  3. current 还没有给 target 发过任何消息（首次接触）
//
// 否则拒绝：current 已经发过且 target 没关注也没回复，进入等待状态。
//
// 返回：
//
//	allow (bool)：是否允许
//	reason (string)：拒绝时的原因码，"waiting_for_reply_or_follow"
//	各种判定中间值用于 send-state 接口
func (h *MessageHandler) canSendMessage(currentUserID, targetID uint) (allow bool, reason string, state messageSendState, err error) {
	state = messageSendState{
		CanSend:          true,
		FirstContactUsed: false,
		TargetFollowsMe:  false,
		TargetReplied:    false,
	}

	// 1. target 关注 current？
	var followCount int64
	if err := h.db.Model(&models.UserFollow{}).
		Where("follower_id = ? AND following_id = ?", targetID, currentUserID).
		Count(&followCount).Error; err != nil {
		return false, "internal_error", state, err
	}
	state.TargetFollowsMe = followCount > 0
	if state.TargetFollowsMe {
		return true, "", state, nil
	}

	// 2. 找一对一会话
	user1ID, user2ID := currentUserID, targetID
	if user1ID > user2ID {
		user1ID, user2ID = user2ID, user1ID
	}
	var conv models.Conversation
	convErr := h.db.Where("user1_id = ? AND user2_id = ?", user1ID, user2ID).First(&conv).Error
	if errors.Is(convErr, gorm.ErrRecordNotFound) {
		// 还没有会话 = current 从未发过 = 允许
		return true, "", state, nil
	}
	if convErr != nil {
		return false, "internal_error", state, convErr
	}

	// 3. target 是否回复过 current
	var targetSentCount int64
	if err := h.db.Model(&models.Message{}).
		Where("conversation_id = ? AND sender_id = ?", conv.ID, targetID).
		Count(&targetSentCount).Error; err != nil {
		return false, "internal_error", state, err
	}
	state.TargetReplied = targetSentCount > 0
	if state.TargetReplied {
		return true, "", state, nil
	}

	// 4. current 是否已发过消息
	var currentSentCount int64
	if err := h.db.Model(&models.Message{}).
		Where("conversation_id = ? AND sender_id = ?", conv.ID, currentUserID).
		Count(&currentSentCount).Error; err != nil {
		return false, "internal_error", state, err
	}
	state.FirstContactUsed = currentSentCount > 0
	if !state.FirstContactUsed {
		return true, "", state, nil
	}

	// 5. 拒绝
	state.CanSend = false
	return false, "waiting_for_reply_or_follow", state, nil
}

// messageSendState 陌生人私信发送状态，用于 send-state 接口
type messageSendState struct {
	CanSend          bool   `json:"can_send"`
	Reason           string `json:"reason,omitempty"`
	FirstContactUsed bool   `json:"first_contact_used"`
	TargetFollowsMe  bool   `json:"target_follows_me"`
	TargetReplied    bool   `json:"target_replied"`
}

// GetSendState GET /api/messages/:user_id/send-state
// 返回陌生人私信发送权限说明，供前端决定输入框是否锁定。
func (h *MessageHandler) GetSendState(c *gin.Context) {
	userID, _ := c.Get("user_id")
	currentUserID := userID.(uint)
	targetUserID, err := strconv.ParseUint(c.Param("user_id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})
		return
	}
	targetID := uint(targetUserID)
	if targetID == currentUserID {
		// 自己不能给自己发，前端也只是查询用，统一返回 can_send=false
		c.JSON(http.StatusOK, messageSendState{CanSend: false, Reason: "self_target"})
		return
	}

	_, reason, state, err := h.canSendMessage(currentUserID, targetID)
	if err != nil {
		log.Printf("[PM_LIMIT] canSendMessage failed current=%d target=%d err=%v", currentUserID, targetID, err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询发送状态失败"})
		return
	}
	// canSendMessage 不填充 Reason 字段当允许时；这里补一次
	if !state.CanSend {
		state.Reason = reason
	}
	c.JSON(http.StatusOK, state)
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
		"type":              "private_message",
		"conversation_id":   message.ConversationID,
		"message_id":        message.ID,
		"sender_id":         sender.ID,
		"sender_name":       title,
		"sender_avatar":     sender.Avatar,
		"recipient_user_id": targetUserID,
	}
	go func() {
		if err := h.notifier.Notify(targetUserID, title, content, extras); err != nil {
			log.Printf("[JPUSH_WARN] private message push failed user=%d conversation=%d err=%v", targetUserID, message.ConversationID, err)
		}
	}()
}

func privateMessagePreview(message models.Message) string {
	content := strings.TrimSpace(message.Content)
	if message.StickerID != nil && (content == "" || content == stickerFallbackText || content == "发来一个表情") {
		return "发来一个表情"
	}
	if content == "" && message.FileID != nil {
		return "发来一张图片"
	}
	return utils.TruncateGraphemes(content, 50)
}

// MarkRead marks all incoming messages in a conversation as read.
func (h *MessageHandler) MarkRead(c *gin.Context) {
	userID, _ := c.Get("user_id")
	convID, ok := h.authorizedConversationID(c, userID.(uint))
	if !ok {
		return
	}

	now := time.Now()
	var readThroughID uint
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.Message{}).
			Where("conversation_id = ? AND sender_id != ? AND read_at IS NULL", convID, userID).
			Update("read_at", now).Error; err != nil {
			return err
		}
		return tx.Model(&models.Message{}).
			Where("conversation_id = ? AND sender_id != ? AND read_at IS NOT NULL", convID, userID).
			Select("COALESCE(MAX(id), 0)").Scan(&readThroughID).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "标记已读失败"})
		return
	}
	var conversation models.Conversation
	if err := h.db.First(&conversation, convID).Error; err == nil {
		h.events.publish(
			[]uint{conversation.User1ID, conversation.User2ID},
			privateMessageEvent{
				Type:           "message.read",
				ConversationID: convID,
				ReadByUserID:   userID.(uint),
				ReadThroughID:  readThroughID,
				ReadAt:         &now,
			},
		)
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
