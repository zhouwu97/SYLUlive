package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const (
	maxFeedbackTicketImages = 6
	maxUserHourlyTickets    = 5
	maxUserHourlyMessages   = 30
)

var (
	errFeedbackTicketStateConflict = errors.New("工单状态已变化，请刷新后重试")
	errFeedbackTicketClosed        = errors.New("该工单已关闭，如仍有问题请点击重新打开")
	errFeedbackTicketRateLimited   = errors.New("feedback_ticket_rate_limited")
)

// feedbackWriteSerialLock 仅用于 SQLite 测试/本地环境；生产环境依赖事务内的
// PostgreSQL 行锁。SQLite 不支持 FOR UPDATE，必须先串行化再做频控计数。
var feedbackWriteSerialLock sync.Mutex

func acquireFeedbackWriteSerialLock(db *gorm.DB) func() {
	if db == nil || db.Dialector == nil || db.Dialector.Name() != "sqlite" {
		return func() {}
	}
	feedbackWriteSerialLock.Lock()
	return feedbackWriteSerialLock.Unlock
}

func (h *FeedbackTicketHandler) recordFeedbackRateLimit(c *gin.Context, userID uint, route string) {
	if h.security == nil {
		return
	}
	_ = h.security.Record(services.SecurityEventInput{
		EventType: "feedback_ticket_flood", Severity: models.SecuritySeverityLow, Route: route, Method: c.Request.Method,
		ClientIP: c.ClientIP(), UserAgent: c.GetHeader("User-Agent"), ActorUserID: &userID, Blocked: true, Action: "rate_limited",
		Metadata: map[string]interface{}{"window": "1h", "route_group": "feedback"},
	})
}

// FeedbackTicketHandler 处理用户端与通用的工单操作
type FeedbackTicketHandler struct {
	db        *gorm.DB
	uploadDir string
	notifier  *services.NotificationService
	security  *services.SecurityEventService
}

// createAdminFeedbackNotifications 为每位管理员创建工单更新通知。
// 使用业务事件键保证同一条用户事件不会因重试产生重复角标。
func (h *FeedbackTicketHandler) createAdminFeedbackNotifications(
	tx *gorm.DB,
	ticket models.FeedbackTicket,
	sourceUserID uint,
	content string,
	eventKey string,
	now time.Time,
) error {
	var admins []models.User
	if err := tx.Select("id").Where("role IN ?", []models.Role{models.RoleAdmin, models.RoleSuperAdmin}).Find(&admins).Error; err != nil {
		return err
	}
	for _, admin := range admins {
		notif := models.Notification{
			UserID:    admin.ID,
			Type:      models.NotificationTypeFeedbackAdminUpdate,
			Content:   content,
			RelatedID: ticket.ID,
			FromUID:   sourceUserID,
			DedupKey:  fmt.Sprintf("%s:admin:%d", eventKey, admin.ID),
			CreatedAt: now,
		}
		if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&notif).Error; err != nil {
			return err
		}
	}
	return nil
}

// feedbackInitialSubmissionResponse 让客户端可以把初始提交和后续对话分开渲染。
// 旧客户端仍通过 ticket.attachments 读取初始附件，因此该字段只做向后兼容扩展。
type feedbackInitialSubmissionResponse struct {
	MessageID   uint                        `json:"message_id"`
	SenderType  string                      `json:"sender_type"`
	SenderID    uint                        `json:"sender_id"`
	Content     string                      `json:"content"`
	CreatedAt   time.Time                   `json:"created_at"`
	Attachments []models.FeedbackAttachment `json:"attachments,omitempty"`
}

// loadFeedbackConversation 会从普通消息流中剥离初始提交消息。
// 历史工单没有 initial_submission 类型时，按最早的用户消息兼容识别，
// 不依赖正文文本去重，避免用户后续发送相同内容时被错误隐藏。
func (h *FeedbackTicketHandler) loadFeedbackConversation(
	ticketID uint,
	visibleToUserOnly bool,
) ([]models.FeedbackMessage, *feedbackInitialSubmissionResponse, error) {
	query := h.db.Where("ticket_id = ?", ticketID).
		Preload("Attachments.File").
		Preload("Sender").
		Order("created_at ASC, id ASC")
	if visibleToUserOnly {
		query = query.Where("visible_to_user = ?", true)
	}

	var allMessages []models.FeedbackMessage
	if err := query.Find(&allMessages).Error; err != nil {
		return nil, nil, err
	}

	initialIndex := -1
	for i := range allMessages {
		if allMessages[i].MessageType == models.FeedbackMsgInitialSubmission {
			initialIndex = i
			break
		}
	}
	if initialIndex < 0 {
		for i := range allMessages {
			if allMessages[i].SenderType == "user" {
				initialIndex = i
				break
			}
		}
	}

	var initial *feedbackInitialSubmissionResponse
	messages := make([]models.FeedbackMessage, 0, len(allMessages))
	for i := range allMessages {
		message := allMessages[i]
		if i == initialIndex {
			initial = &feedbackInitialSubmissionResponse{
				MessageID:   message.ID,
				SenderType:  message.SenderType,
				SenderID:    message.SenderID,
				Content:     message.Content,
				CreatedAt:   message.CreatedAt,
				Attachments: message.Attachments,
			}
			continue
		}
		messages = append(messages, message)
	}
	return messages, initial, nil
}

// NewFeedbackTicketHandler 创建工单处理器
func NewFeedbackTicketHandler(db *gorm.DB, uploadDir string, notifier *services.NotificationService) *FeedbackTicketHandler {
	return &FeedbackTicketHandler{
		db:        db,
		uploadDir: uploadDir,
		notifier:  notifier,
	}
}

// SetSecurityEventService 注入安全事件记录器。
func (h *FeedbackTicketHandler) SetSecurityEventService(security *services.SecurityEventService) {
	h.security = security
}

// CreateTicketInput 用户提交新工单参数
type CreateTicketInput struct {
	Type             string `json:"type" binding:"required"`
	Title            string `json:"title" binding:"required"`
	Description      string `json:"description" binding:"required"`
	StepsToReproduce string `json:"steps_to_reproduce"`
	ActualResult     string `json:"actual_result"`
	ExpectedResult   string `json:"expected_result"`
	ImageIDs         []uint `json:"image_ids"`

	// 诊断信息（非敏感）
	AppVersion      string `json:"app_version"`
	BuildNumber     string `json:"build_number"`
	DeviceModel     string `json:"device_model"`
	OSVersion       string `json:"os_version"`
	NetworkType     string `json:"network_type"`
	CurrentRoute    string `json:"current_route"`
	DiagnosticsJSON string `json:"diagnostics_json"`
}

// CreateTicket 提交新工单
func (h *FeedbackTicketHandler) CreateTicket(c *gin.Context) {
	rawUID, ok := c.Get("user_id")
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录后提交反馈"})
		return
	}
	userID := rawUID.(uint)
	if userID == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录后提交反馈"})
		return
	}

	var input CreateTicketInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数不完整，请填写标题和描述"})
		return
	}

	input.Title = strings.TrimSpace(input.Title)
	input.Description = strings.TrimSpace(input.Description)
	if len([]rune(input.Title)) == 0 || len([]rune(input.Title)) > 120 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "标题长度必须在 1 到 120 字之间"})
		return
	}
	if len([]rune(input.Description)) == 0 || len([]rune(input.Description)) > 2000 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "问题描述长度必须在 1 到 2000 字之间"})
		return
	}

	ticketType := strings.ToLower(strings.TrimSpace(input.Type))
	if ticketType != models.FeedbackTypeBug && ticketType != models.FeedbackTypeSuggestion && ticketType != models.FeedbackTypeOther {
		ticketType = models.FeedbackTypeBug
	}

	// 图片校验
	var attachedFiles []models.File
	if len(input.ImageIDs) > 0 {
		files, err := services.ValidateImageFileIDs(h.db, input.ImageIDs, maxFeedbackTicketImages, userID)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "截图无效或包含非法文件，请重新上传"})
			return
		}
		attachedFiles = files
	}

	// 敏感诊断信息过滤清洗（绝不允许携带 jwt, token, password, cookie, auth）
	sanitizedDiagnostics := sanitizeDiagnosticsJSON(input.DiagnosticsJSON)

	now := time.Now()
	ticketNo := models.GenerateTicketNo(now)

	ticket := models.FeedbackTicket{
		TicketNo:         ticketNo,
		UserID:           userID,
		Type:             ticketType,
		Title:            input.Title,
		Description:      input.Description,
		StepsToReproduce: strings.TrimSpace(input.StepsToReproduce),
		ActualResult:     strings.TrimSpace(input.ActualResult),
		ExpectedResult:   strings.TrimSpace(input.ExpectedResult),
		Status:           models.FeedbackStatusPending,
		StatusNote:       "工单已提交，等待管理员查看受理",
		Priority:         models.FeedbackPriorityP2,
		AdminViewed:      false,
		AppVersion:       strings.TrimSpace(input.AppVersion),
		BuildNumber:      strings.TrimSpace(input.BuildNumber),
		DeviceModel:      strings.TrimSpace(input.DeviceModel),
		OSVersion:        strings.TrimSpace(input.OSVersion),
		NetworkType:      strings.TrimSpace(input.NetworkType),
		CurrentRoute:     strings.TrimSpace(input.CurrentRoute),
		DiagnosticsJSON:  sanitizedDiagnostics,
		CreatedAt:        now,
		UpdatedAt:        now,
	}

	releaseWriteLock := acquireFeedbackWriteSerialLock(h.db)
	defer releaseWriteLock()

	err := h.db.Transaction(func(tx *gorm.DB) error {
		// PostgreSQL 依赖用户行锁串行化同一账号的频控计数与插入；SQLite
		// 由上面的进程内锁补足 FOR UPDATE 不生效的测试语义。
		var owner models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Select("id").First(&owner, userID).Error; err != nil {
			return err
		}
		var recentCount int64
		if err := tx.Model(&models.FeedbackTicket{}).
			Where("user_id = ? AND created_at >= ?", userID, now.Add(-1*time.Hour)).
			Count(&recentCount).Error; err != nil {
			return err
		}
		if recentCount >= maxUserHourlyTickets {
			return errFeedbackTicketRateLimited
		}
		if err := tx.Create(&ticket).Error; err != nil {
			return err
		}

		// 创建初始工单流水消息
		msg := models.FeedbackMessage{
			TicketID:      ticket.ID,
			SenderType:    "user",
			SenderID:      userID,
			MessageType:   models.FeedbackMsgInitialSubmission,
			Content:       input.Description,
			VisibleToUser: true,
			CreatedAt:     now,
		}
		if err := tx.Create(&msg).Error; err != nil {
			return err
		}

		// 关联图片附件并 claim 私有状态
		if len(attachedFiles) > 0 {
			for _, file := range attachedFiles {
				att := models.FeedbackAttachment{
					TicketID:   ticket.ID,
					MessageID:  &msg.ID,
					FileID:     file.ID,
					UploaderID: userID,
					CreatedAt:  now,
				}
				if err := tx.Create(&att).Error; err != nil {
					return err
				}
			}
			if err := services.ClaimPrivateFiles(tx, input.ImageIDs); err != nil {
				return err
			}
		}

		// 创建初始状态流水
		history := models.FeedbackStatusHistory{
			TicketID:     ticket.ID,
			OperatorID:   userID,
			OperatorType: "user",
			OldStatus:    "",
			NewStatus:    models.FeedbackStatusPending,
			Note:         "工单已提交",
			CreatedAt:    now,
		}
		if err := tx.Create(&history).Error; err != nil {
			return err
		}
		return h.createAdminFeedbackNotifications(
			tx,
			ticket,
			userID,
			fmt.Sprintf("收到新的用户工单：#%s %s", ticket.TicketNo, ticket.Title),
			fmt.Sprintf("feedback-created:%d", ticket.ID),
			now,
		)
	})

	if err != nil {
		if errors.Is(err, errFeedbackTicketRateLimited) {
			h.recordFeedbackRateLimit(c, userID, "/api/feedback/tickets")
			c.JSON(http.StatusTooManyRequests, gin.H{"error": "提交过于频繁，请稍后再试"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "提交反馈失败，请稍后重试"})
		return
	}

	c.JSON(http.StatusCreated, gin.H{
		"message": "反馈已提交，我们会持续跟进处理！",
		"ticket":  ticket,
	})
}

// ListMyTickets 用户获取自己的工单列表
func (h *FeedbackTicketHandler) ListMyTickets(c *gin.Context) {
	rawUID, ok := c.Get("user_id")
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录"})
		return
	}
	userID := rawUID.(uint)

	statusGroup := strings.ToLower(strings.TrimSpace(c.Query("status_group")))
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "20"))
	if page <= 0 {
		page = 1
	}
	if limit <= 0 || limit > 50 {
		limit = 20
	}
	offset := (page - 1) * limit

	query := h.db.Model(&models.FeedbackTicket{}).Where("user_id = ?", userID)

	switch statusGroup {
	case "processing":
		query = query.Where("status IN ?", []string{
			models.FeedbackStatusPending,
			models.FeedbackStatusAccepted,
			models.FeedbackStatusInvestigating,
			models.FeedbackStatusFixing,
			models.FeedbackStatusTesting,
		})
	case "waiting_user":
		query = query.Where("status = ?", models.FeedbackStatusWaitingUser)
	case "resolved":
		query = query.Where("status IN ?", []string{
			models.FeedbackStatusResolved,
			models.FeedbackStatusClosed,
		})
	default:
		// "all" 全部
	}

	var total int64
	if err := query.Count(&total).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取工单列表失败"})
		return
	}

	var tickets []models.FeedbackTicket
	if err := query.Order("updated_at DESC, id DESC").Offset(offset).Limit(limit).Find(&tickets).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取工单列表失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"total":   total,
		"page":    page,
		"limit":   limit,
		"tickets": tickets,
	})
}

// GetUnreadCount 获取用户未读工单回复数量（用于「我的」页面角标）
func (h *FeedbackTicketHandler) GetUnreadCount(c *gin.Context) {
	rawUID, ok := c.Get("user_id")
	if !ok {
		c.JSON(http.StatusOK, gin.H{"unread_count": 0})
		return
	}
	userID := rawUID.(uint)

	var count int64
	// 用户有未读消息的工单数
	if err := h.db.Model(&models.FeedbackTicket{}).
		Where("user_id = ? AND user_unread_count > 0", userID).
		Count(&count).Error; err != nil {
		c.JSON(http.StatusOK, gin.H{"unread_count": 0})
		return
	}

	c.JSON(http.StatusOK, gin.H{"unread_count": count})
}

// GetTicketDetail 用户获取工单详情
func (h *FeedbackTicketHandler) GetTicketDetail(c *gin.Context) {
	rawUID, ok := c.Get("user_id")
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录"})
		return
	}
	userID := rawUID.(uint)
	ticketID := c.Param("id")

	var ticket models.FeedbackTicket
	if err := h.db.Where("id = ? AND user_id = ?", ticketID, userID).First(&ticket).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "工单不存在或无权查看"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取工单失败"})
		return
	}

	// 读取对用户可见的消息流水，并将初始提交从普通对话中剥离。
	messages, initialSubmission, err := h.loadFeedbackConversation(ticket.ID, true)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取工单消息失败"})
		return
	}

	// 初始附件优先从初始消息读取；兼容历史上 message_id 为空的附件记录。
	var attachments []models.FeedbackAttachment
	if initialSubmission != nil {
		attachments = initialSubmission.Attachments
	}
	if len(attachments) == 0 {
		if err := h.db.Where("ticket_id = ? AND (message_id IS NULL OR message_id = 0)", ticket.ID).
			Preload("File").
			Find(&attachments).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "读取工单附件失败"})
			return
		}
	}
	ticket.Attachments = attachments
	if initialSubmission != nil && len(initialSubmission.Attachments) == 0 {
		initialSubmission.Attachments = attachments
	}

	// 读取状态流转记录
	var history []models.FeedbackStatusHistory
	if err := h.db.Where("ticket_id = ?", ticket.ID).Order("created_at ASC").Find(&history).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取工单变更记录失败"})
		return
	}

	// 只清除本次响应已读到的边界；若期间出现新的管理员消息，保留未读提示。
	if ticket.UserUnreadCount > 0 {
		readThroughID := uint(0)
		for _, message := range messages {
			if message.ID > readThroughID {
				readThroughID = message.ID
			}
		}
		result := h.db.Model(&models.FeedbackTicket{}).
			Where("id = ? AND user_unread_count > 0", ticket.ID).
			Where("NOT EXISTS (SELECT 1 FROM feedback_messages WHERE ticket_id = ? AND sender_type = ? AND visible_to_user = ? AND id > ?)", ticket.ID, "admin", true, readThroughID).
			Update("user_unread_count", 0)
		if result.Error == nil && result.RowsAffected > 0 {
			ticket.UserUnreadCount = 0
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"ticket":             ticket,
		"initial_submission": initialSubmission,
		"messages":           messages,
		"history":            history,
	})
}

// UserAddMessageInput 用户回复/补充消息
type UserAddMessageInput struct {
	Content  string `json:"content" binding:"required"`
	ImageIDs []uint `json:"image_ids"`
}

// AddMessage 用户在工单中追加回复
func (h *FeedbackTicketHandler) AddMessage(c *gin.Context) {
	rawUID, ok := c.Get("user_id")
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录"})
		return
	}
	userID := rawUID.(uint)
	ticketID := c.Param("id")

	var ticket models.FeedbackTicket
	if err := h.db.Where("id = ? AND user_id = ?", ticketID, userID).First(&ticket).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "工单不存在或无权访问"})
		return
	}

	if ticket.Status == models.FeedbackStatusClosed {
		c.JSON(http.StatusConflict, gin.H{"code": "feedback_closed", "error": "该工单已关闭，如仍有问题请点击重新打开"})
		return
	}

	var input UserAddMessageInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "回复内容不能为空"})
		return
	}
	input.Content = strings.TrimSpace(input.Content)
	if len([]rune(input.Content)) == 0 || len([]rune(input.Content)) > 1000 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "回复内容长度必须在 1 到 1000 字之间"})
		return
	}

	// 图片校验
	var attachedFiles []models.File
	if len(input.ImageIDs) > 0 {
		files, err := services.ValidateImageFileIDs(h.db, input.ImageIDs, maxFeedbackTicketImages, userID)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "截图无效，请重新上传"})
			return
		}
		attachedFiles = files
	}

	now := time.Now()
	msg := models.FeedbackMessage{
		TicketID:      ticket.ID,
		SenderType:    "user",
		SenderID:      userID,
		MessageType:   models.FeedbackMsgText,
		Content:       input.Content,
		VisibleToUser: true,
		CreatedAt:     now,
	}

	releaseWriteLock := acquireFeedbackWriteSerialLock(h.db)
	defer releaseWriteLock()

	err := h.db.Transaction(func(tx *gorm.DB) error {
		var lockedTicket models.FeedbackTicket
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("id = ? AND user_id = ?", ticketID, userID).
			First(&lockedTicket).Error; err != nil {
			return err
		}
		if lockedTicket.Status == models.FeedbackStatusClosed {
			return errFeedbackTicketClosed
		}
		ticket = lockedTicket
		var msgCount int64
		if err := tx.Model(&models.FeedbackMessage{}).
			Where("ticket_id = ? AND sender_type = 'user' AND created_at >= ?", ticket.ID, now.Add(-1*time.Hour)).
			Count(&msgCount).Error; err != nil {
			return err
		}
		if msgCount >= maxUserHourlyMessages {
			return errFeedbackTicketRateLimited
		}
		if err := tx.Create(&msg).Error; err != nil {
			return err
		}

		if len(attachedFiles) > 0 {
			for _, file := range attachedFiles {
				att := models.FeedbackAttachment{
					TicketID:   ticket.ID,
					MessageID:  &msg.ID,
					FileID:     file.ID,
					UploaderID: userID,
					CreatedAt:  now,
				}
				if err := tx.Create(&att).Error; err != nil {
					return err
				}
			}
			if err := services.ClaimPrivateFiles(tx, input.ImageIDs); err != nil {
				return err
			}
		}

		updates := map[string]interface{}{
			"updated_at":   now,
			"admin_viewed": false, // 管理员未读
		}

		// 若原状态为「待用户补充」，用户回复后自动转为「已受理」
		if ticket.Status == models.FeedbackStatusWaitingUser {
			updates["status"] = models.FeedbackStatusAccepted
			updates["status_note"] = "用户已补充信息，等待处理"

			history := models.FeedbackStatusHistory{
				TicketID:     ticket.ID,
				OperatorID:   userID,
				OperatorType: "user",
				OldStatus:    models.FeedbackStatusWaitingUser,
				NewStatus:    models.FeedbackStatusAccepted,
				Note:         "用户已补充相关信息",
				CreatedAt:    now,
			}
			if err := tx.Create(&history).Error; err != nil {
				return err
			}
		}
		if err := h.createAdminFeedbackNotifications(
			tx,
			ticket,
			userID,
			fmt.Sprintf("工单 #%s 收到用户补充：%s", ticket.TicketNo, feedbackSnippetForColumn(input.Content, 120)),
			fmt.Sprintf("feedback-message:%d", msg.ID),
			now,
		); err != nil {
			return err
		}

		return tx.Model(&ticket).Updates(updates).Error
	})

	if err != nil {
		if errors.Is(err, errFeedbackTicketRateLimited) {
			h.recordFeedbackRateLimit(c, userID, "/api/feedback/tickets/:id/messages")
			c.JSON(http.StatusTooManyRequests, gin.H{"error": "发言过于频繁，请稍后再试"})
			return
		}
		if errors.Is(err, errFeedbackTicketClosed) {
			c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "发送回复失败，请稍后重试"})
		return
	}

	_ = h.db.Preload("Attachments.File").Preload("Sender").First(&msg, msg.ID).Error

	c.JSON(http.StatusOK, gin.H{
		"message": msg,
		"ticket":  ticket,
	})
}

// ReopenTicketInput 重新打开工单入参
type ReopenTicketInput struct {
	Reason string `json:"reason" binding:"required"`
}

// ReopenTicket 用户点击「仍有问题」，重新打开工单
func (h *FeedbackTicketHandler) ReopenTicket(c *gin.Context) {
	rawUID, ok := c.Get("user_id")
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录"})
		return
	}
	userID := rawUID.(uint)
	ticketID := c.Param("id")

	var ticket models.FeedbackTicket
	if err := h.db.Where("id = ? AND user_id = ?", ticketID, userID).First(&ticket).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "工单不存在或无权访问"})
		return
	}

	if ticket.Status != models.FeedbackStatusResolved && ticket.Status != models.FeedbackStatusClosed {
		c.JSON(http.StatusBadRequest, gin.H{"error": "当前工单仍在处理中，无需重新打开"})
		return
	}

	var input ReopenTicketInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请说明仍存在的问题"})
		return
	}
	input.Reason = strings.TrimSpace(input.Reason)
	if len([]rune(input.Reason)) == 0 || len([]rune(input.Reason)) > 500 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "说明内容长度必须在 1 到 500 字之间"})
		return
	}

	now := time.Now()
	oldStatus := ticket.Status
	newStatus := models.FeedbackStatusInvestigating

	err := h.db.Transaction(func(tx *gorm.DB) error {
		var lockedTicket models.FeedbackTicket
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("id = ? AND user_id = ?", ticketID, userID).
			First(&lockedTicket).Error; err != nil {
			return err
		}
		if lockedTicket.Status != models.FeedbackStatusResolved &&
			lockedTicket.Status != models.FeedbackStatusClosed {
			return errFeedbackTicketStateConflict
		}
		ticket = lockedTicket
		oldStatus = lockedTicket.Status
		statusNote := "用户反馈问题仍存在：" + input.Reason
		updates := map[string]interface{}{
			"status":       newStatus,
			"status_note":  statusNote,
			"admin_viewed": false,
			"updated_at":   now,
			"resolved_at":  nil,
			"closed_at":    nil,
		}
		if err := tx.Model(&ticket).Updates(updates).Error; err != nil {
			return err
		}

		history := models.FeedbackStatusHistory{
			TicketID:     ticket.ID,
			OperatorID:   userID,
			OperatorType: "user",
			OldStatus:    oldStatus,
			NewStatus:    newStatus,
			Note:         statusNote,
			CreatedAt:    now,
		}
		if err := tx.Create(&history).Error; err != nil {
			return err
		}

		msg := models.FeedbackMessage{
			TicketID:      ticket.ID,
			SenderType:    "user",
			SenderID:      userID,
			MessageType:   models.FeedbackMsgStatusChange,
			Content:       "重新打开工单：用户反馈问题仍未完全解决",
			MetadataJSON:  fmt.Sprintf(`{"reason":%q}`, input.Reason),
			VisibleToUser: true,
			CreatedAt:     now,
		}
		if err := tx.Create(&msg).Error; err != nil {
			return err
		}
		return h.createAdminFeedbackNotifications(
			tx,
			ticket,
			userID,
			fmt.Sprintf("工单 #%s 已由用户重新打开：%s", ticket.TicketNo, input.Reason),
			fmt.Sprintf("feedback-reopen:%d", msg.ID),
			now,
		)
	})

	if err != nil {
		if errors.Is(err, errFeedbackTicketStateConflict) {
			c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "重新打开工单失败，请稍后重试"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"message": "工单已重新打开，我们会尽快进一步跟进定位！",
		"ticket":  ticket,
	})
}

// ConfirmResolved 用户点击「已解决」，确认关闭工单
func (h *FeedbackTicketHandler) ConfirmResolved(c *gin.Context) {
	rawUID, ok := c.Get("user_id")
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录"})
		return
	}
	userID := rawUID.(uint)
	ticketID := c.Param("id")

	var ticket models.FeedbackTicket
	if err := h.db.Where("id = ? AND user_id = ?", ticketID, userID).First(&ticket).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "工单不存在或无权访问"})
		return
	}

	now := time.Now()
	oldStatus := ticket.Status
	newStatus := models.FeedbackStatusClosed

	err := h.db.Transaction(func(tx *gorm.DB) error {
		var lockedTicket models.FeedbackTicket
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("id = ? AND user_id = ?", ticketID, userID).
			First(&lockedTicket).Error; err != nil {
			return err
		}
		if lockedTicket.Status != models.FeedbackStatusResolved {
			return errFeedbackTicketStateConflict
		}
		ticket = lockedTicket
		oldStatus = lockedTicket.Status
		updates := map[string]interface{}{
			"status":      newStatus,
			"status_note": "用户已确认问题解决，工单关闭",
			"closed_at":   now,
			"updated_at":  now,
		}
		if err := tx.Model(&ticket).Updates(updates).Error; err != nil {
			return err
		}

		history := models.FeedbackStatusHistory{
			TicketID:     ticket.ID,
			OperatorID:   userID,
			OperatorType: "user",
			OldStatus:    oldStatus,
			NewStatus:    newStatus,
			Note:         "用户确认问题已解决",
			CreatedAt:    now,
		}
		if err := tx.Create(&history).Error; err != nil {
			return err
		}

		msg := models.FeedbackMessage{
			TicketID:      ticket.ID,
			SenderType:    "user",
			SenderID:      userID,
			MessageType:   models.FeedbackMsgStatusChange,
			Content:       "用户已确认问题解决，工单顺利归档",
			VisibleToUser: true,
			CreatedAt:     now,
		}
		return tx.Create(&msg).Error
	})

	if err != nil {
		if errors.Is(err, errFeedbackTicketStateConflict) {
			c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "操作失败，请稍后重试"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"message": "感谢你的反馈与确认！",
		"ticket":  ticket,
	})
}

// ServeAttachment 鉴权访问私有截图附件（防越权与私密信息泄漏）
func (h *FeedbackTicketHandler) ServeAttachment(c *gin.Context) {
	rawUID, ok := c.Get("user_id")
	if !ok {
		c.Status(http.StatusNotFound)
		return
	}
	userID := rawUID.(uint)
	fileIDRaw := c.Param("file_id")

	fileID, err := strconv.ParseUint(fileIDRaw, 10, 64)
	if err != nil || fileID == 0 {
		c.Status(http.StatusNotFound)
		return
	}

	// 检查当前用户是否为管理员
	var user models.User
	isAdmin := false
	if err := h.db.Select("id, role").First(&user, userID).Error; err == nil {
		isAdmin = user.Role == models.RoleAdmin || user.Role == models.RoleSuperAdmin
	}

	// 同一文件可能被多个工单复用，必须按本次工单引用逐条授权，不能取最早引用。
	var references []models.FeedbackAttachment
	if err := h.db.Where("file_id = ?", fileID).Find(&references).Error; err != nil || len(references) == 0 {
		c.Status(http.StatusNotFound)
		return
	}
	var attachment models.FeedbackAttachment
	authorized := false
	for _, candidate := range references {
		if isAdmin {
			attachment, authorized = candidate, true
			break
		}
		var ownedTicket models.FeedbackTicket
		if err := h.db.Select("id, user_id").First(&ownedTicket, candidate.TicketID).Error; err != nil || ownedTicket.UserID != userID {
			continue
		}
		if candidate.MessageID != nil && *candidate.MessageID != 0 {
			var message models.FeedbackMessage
			if err := h.db.Select("id, visible_to_user").First(&message, *candidate.MessageID).Error; err != nil || !message.VisibleToUser {
				continue
			}
		}
		attachment, authorized = candidate, true
		break
	}
	if !authorized {
		c.Status(http.StatusNotFound)
		return
	}

	// 若非管理员，必须是工单所有者
	if !isAdmin {
		var ticket models.FeedbackTicket
		if err := h.db.Select("id, user_id").First(&ticket, attachment.TicketID).Error; err != nil {
			c.Status(http.StatusNotFound)
			return
		}
		if ticket.UserID != userID {
			c.Status(http.StatusNotFound)
			return
		}
	}

	// 读取文件实体与路径
	var file models.File
	if err := h.db.First(&file, fileID).Error; err != nil {
		c.Status(http.StatusNotFound)
		return
	}

	fullPath, err := services.ResolveUploadPath(h.uploadDir, file.Path)
	if err != nil {
		c.Status(http.StatusNotFound)
		return
	}
	if _, err := os.Stat(fullPath); err != nil {
		c.Status(http.StatusNotFound)
		return
	}

	c.Header("Content-Type", file.MimeType)
	c.Header("Cache-Control", "private, no-store")
	c.Header("X-Content-Type-Options", "nosniff")
	c.File(fullPath)
}

// sanitizeDiagnosticsJSON 移除一切可能携带的敏感信息
func sanitizeDiagnosticsJSON(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "{}"
	}
	var data map[string]interface{}
	if err := json.Unmarshal([]byte(raw), &data); err != nil {
		return "{}"
	}

	sensitiveKeys := []string{
		"token", "jwt", "authorization", "auth", "cookie", "password", "secret",
		"key", "session", "credential", "chat", "message",
	}

	var cleanValue interface{}
	var clean func(interface{}) interface{}
	clean = func(value interface{}) interface{} {
		switch typed := value.(type) {
		case map[string]interface{}:
			out := make(map[string]interface{}, len(typed))
			for k, v := range typed {
				lowerKey := strings.ToLower(k)
				sensitive := false
				for _, s := range sensitiveKeys {
					if strings.Contains(lowerKey, s) {
						sensitive = true
						break
					}
				}
				if !sensitive {
					out[k] = clean(v)
				}
			}
			return out
		case []interface{}:
			out := make([]interface{}, len(typed))
			for i, item := range typed {
				out[i] = clean(item)
			}
			return out
		default:
			return value
		}
	}
	cleanValue = clean(data)

	out, err := json.Marshal(cleanValue)
	if err != nil {
		return "{}"
	}
	return string(out)
}
