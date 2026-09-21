package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// feedbackSnippetForColumn 只限制列表摘要，不截断工单正文、消息或状态历史。
func feedbackSnippetForColumn(value string, max int) string {
	runes := []rune(value)
	if len(runes) <= max {
		return value
	}
	if max <= 3 {
		return string(runes[:max])
	}
	return string(runes[:max-3]) + "..."
}

// AdminListTickets 管理员查询工单列表
func (h *FeedbackTicketHandler) AdminListTickets(c *gin.Context) {
	statusFilter := strings.ToLower(strings.TrimSpace(c.Query("status_filter")))
	search := strings.TrimSpace(c.Query("search"))
	priority := strings.ToUpper(strings.TrimSpace(c.Query("priority")))
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "20"))
	if page <= 0 {
		page = 1
	}
	if limit <= 0 || limit > 50 {
		limit = 20
	}
	offset := (page - 1) * limit

	query := h.db.Model(&models.FeedbackTicket{}).Preload("User").Preload("AssigneeAdmin")

	switch statusFilter {
	case "unviewed":
		query = query.Where("admin_viewed = ?", false)
	case "pending":
		query = query.Where("status = ?", models.FeedbackStatusPending)
	case "processing":
		query = query.Where("status IN ?", []string{
			models.FeedbackStatusAccepted,
			models.FeedbackStatusInvestigating,
			models.FeedbackStatusFixing,
		})
	case "testing":
		query = query.Where("status = ?", models.FeedbackStatusTesting)
	case "waiting_user":
		query = query.Where("status = ?", models.FeedbackStatusWaitingUser)
	case "resolved":
		query = query.Where("status = ?", models.FeedbackStatusResolved)
	case "closed":
		query = query.Where("status = ?", models.FeedbackStatusClosed)
	default:
		// "all" 不按状态过滤
	}

	if priority != "" && (priority == "P0" || priority == "P1" || priority == "P2" || priority == "P3") {
		query = query.Where("priority = ?", priority)
	}

	if search != "" {
		likePattern := "%" + search + "%"
		query = query.Where("ticket_no ILIKE ? OR title ILIKE ? OR description ILIKE ?", likePattern, likePattern, likePattern)
	}

	var total int64
	if err := query.Count(&total).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询工单失败"})
		return
	}

	var tickets []models.FeedbackTicket
	if err := query.Order("updated_at DESC, id DESC").Offset(offset).Limit(limit).Find(&tickets).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询工单失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"total":    total,
		"page":     page,
		"limit":    limit,
		"has_more": int64(offset+len(tickets)) < total,
		"tickets":  tickets,
	})
}

// AdminGetStats 管理员获取工单数据概览
func (h *FeedbackTicketHandler) AdminGetStats(c *gin.Context) {
	var pendingCount int64
	var waitingUserCount int64
	var testingCount int64
	var unviewedCount int64
	var totalUnresolved int64

	// 概览计数失败时不能返回全 0：那会让管理端角标显示成"没有待处理工单"。
	counts := []struct {
		query *gorm.DB
		dest  *int64
	}{
		{h.db.Model(&models.FeedbackTicket{}).Where("status = ?", models.FeedbackStatusPending), &pendingCount},
		{h.db.Model(&models.FeedbackTicket{}).Where("status = ?", models.FeedbackStatusWaitingUser), &waitingUserCount},
		{h.db.Model(&models.FeedbackTicket{}).Where("status = ?", models.FeedbackStatusTesting), &testingCount},
		{h.db.Model(&models.FeedbackTicket{}).Where("admin_viewed = ?", false), &unviewedCount},
		{h.db.Model(&models.FeedbackTicket{}).
			Where("status NOT IN ?", []string{models.FeedbackStatusResolved, models.FeedbackStatusClosed}), &totalUnresolved},
	}
	for _, count := range counts {
		if err := count.query.Count(count.dest).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "读取工单概览失败"})
			return
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"pending_count":      pendingCount,
		"waiting_user_count": waitingUserCount,
		"testing_count":      testingCount,
		"unviewed_count":     unviewedCount,
		"total_unresolved":   totalUnresolved,
	})
}

// AdminGetTicketDetail 管理员获取工单详情（包含内部备注，且标记已查看）
func (h *FeedbackTicketHandler) AdminGetTicketDetail(c *gin.Context) {
	ticketID := c.Param("id")

	var ticket models.FeedbackTicket
	if err := h.db.Preload("User").Preload("AssigneeAdmin").First(&ticket, ticketID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "工单不存在"})
		return
	}

	// 先完整读取详情，确认响应内容可用后再标记管理队列已查看。
	messages, initialSubmission, err := h.loadFeedbackConversation(ticket.ID, false)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取消息失败"})
		return
	}

	// 初始附件优先从初始消息读取，兼容历史 message_id 为空的记录。
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

	// 状态变更记录
	var history []models.FeedbackStatusHistory
	if err := h.db.Where("ticket_id = ?", ticket.ID).Order("created_at ASC").Find(&history).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取工单变更记录失败"})
		return
	}

	// 只把本次完整读取到的用户消息标记为已查看。若读取过程中出现新用户消息，
	// 条件更新不会命中，避免新消息被误判为已读；该操作不推进业务 updated_at。
	if !ticket.AdminViewed {
		now := time.Now()
		lastUserMessageID := uint(0)
		for _, message := range messages {
			if message.SenderType == "user" && message.ID > lastUserMessageID {
				lastUserMessageID = message.ID
			}
		}
		if initialSubmission != nil && initialSubmission.SenderType == "user" && initialSubmission.MessageID > lastUserMessageID {
			lastUserMessageID = initialSubmission.MessageID
		}

		updates := map[string]interface{}{"admin_viewed": true}
		if ticket.AdminFirstViewedAt == nil {
			updates["admin_first_viewed_at"] = now
		}
		result := h.db.Model(&models.FeedbackTicket{}).
			Where("id = ? AND admin_viewed = ?", ticket.ID, false).
			Where("NOT EXISTS (SELECT 1 FROM feedback_messages WHERE ticket_id = ? AND sender_type = ? AND id > ?)", ticket.ID, "user", lastUserMessageID).
			UpdateColumns(updates)
		if result.Error != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "标记工单已读失败"})
			return
		}
		if result.RowsAffected > 0 {
			ticket.AdminViewed = true
			if ticket.AdminFirstViewedAt == nil {
				ticket.AdminFirstViewedAt = &now
			}
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"ticket":             ticket,
		"initial_submission": initialSubmission,
		"messages":           messages,
		"history":            history,
	})
}

// AdminAddMessageInput 管理员发送消息入参
type AdminAddMessageInput struct {
	Content       string `json:"content" binding:"required"`
	VisibleToUser bool   `json:"visible_to_user"` // true: 回复用户, false: 内部备注
	ImageIDs      []uint `json:"image_ids"`
}

// AdminAddMessage 管理员回复用户或添加内部备注
func (h *FeedbackTicketHandler) AdminAddMessage(c *gin.Context) {
	rawUID, _ := c.Get("user_id")
	adminID := rawUID.(uint)
	ticketID := c.Param("id")

	var input AdminAddMessageInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "内容不能为空"})
		return
	}
	input.Content = strings.TrimSpace(input.Content)
	if len([]rune(input.Content)) == 0 || len([]rune(input.Content)) > 2000 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "内容长度必须在 1 到 2000 字之间"})
		return
	}

	// 图片校验
	var attachedFiles []models.File
	if len(input.ImageIDs) > 0 {
		files, err := services.ValidateImageFileIDs(h.db, input.ImageIDs, maxFeedbackTicketImages, adminID)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "截图校验失败，请重新上传"})
			return
		}
		attachedFiles = files
	}

	msgType := models.FeedbackMsgText
	if !input.VisibleToUser {
		msgType = models.FeedbackMsgInternalNote
	}

	var ticket models.FeedbackTicket
	var msg models.FeedbackMessage
	autoAccepted := false

	err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			First(&ticket, ticketID).Error; err != nil {
			return err
		}
		if input.VisibleToUser && ticket.Status == models.FeedbackStatusClosed {
			return errFeedbackTicketClosed
		}

		now := time.Now()
		msg = models.FeedbackMessage{
			TicketID:      ticket.ID,
			SenderType:    "admin",
			SenderID:      adminID,
			MessageType:   msgType,
			Content:       input.Content,
			VisibleToUser: input.VisibleToUser,
			CreatedAt:     now,
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
					UploaderID: adminID,
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

		ticketUpdates := map[string]interface{}{
			"updated_at": now,
		}

		if input.VisibleToUser {
			ticketUpdates["user_unread_count"] = gorm.Expr("user_unread_count + 1")
			snippet := input.Content
			if len([]rune(snippet)) > 30 {
				snippet = string([]rune(snippet)[:30]) + "..."
			}
			ticketUpdates["latest_reply_snippet"] = "官方：" + snippet

			// 首次公开回复代表管理员已经开始处理，但查看详情本身不应自动受理。
			if ticket.Status == models.FeedbackStatusPending {
				autoAccepted = true
				ticketUpdates["status"] = models.FeedbackStatusAccepted
				ticketUpdates["status_note"] = "管理员已回复，工单已受理"
				history := models.FeedbackStatusHistory{
					TicketID:     ticket.ID,
					OperatorID:   adminID,
					OperatorType: "admin",
					OldStatus:    models.FeedbackStatusPending,
					NewStatus:    models.FeedbackStatusAccepted,
					Note:         "首次官方公开回复自动受理",
					CreatedAt:    now,
				}
				if err := tx.Create(&history).Error; err != nil {
					return err
				}
			}

			// 创建站内通知
			notif := models.Notification{
				UserID:    ticket.UserID,
				Type:      "feedback_update",
				Content:   fmt.Sprintf("工单 #%s 收到管理员新回复：%s", ticket.TicketNo, snippet),
				RelatedID: ticket.ID,
				FromUID:   adminID,
				CreatedAt: now,
			}
			if err := tx.Create(&notif).Error; err != nil {
				return err
			}
		}

		return tx.Model(&ticket).Updates(ticketUpdates).Error
	})

	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "工单不存在"})
			return
		}
		if errors.Is(err, errFeedbackTicketClosed) {
			c.JSON(http.StatusConflict, gin.H{"code": "feedback_closed_public_reply", "error": err.Error()})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "消息发送失败"})
		return
	}

	// 如果对用户可见，触发 JPush 推送
	if input.VisibleToUser && h.notifier != nil {
		pushTitle := "【反馈工单】官方已回复你的反馈"
		pushContent := fmt.Sprintf("工单 #%s: %s", ticket.TicketNo, input.Content)
		if len([]rune(pushContent)) > 60 {
			pushContent = string([]rune(pushContent)[:60]) + "..."
		}
		_ = h.notifier.Notify(ticket.UserID, pushTitle, pushContent, map[string]interface{}{
			"type":              "feedback_ticket",
			"ticket_id":         ticket.ID,
			"recipient_user_id": ticket.UserID,
		})
	}

	_ = h.db.Preload("Attachments.File").Preload("Sender").First(&msg, msg.ID).Error
	_ = h.db.Preload("User").Preload("AssigneeAdmin").First(&ticket, ticket.ID).Error

	c.JSON(http.StatusOK, gin.H{
		"message":       msg,
		"ticket":        ticket,
		"auto_accepted": autoAccepted,
	})
}

// AdminUpdateStatusInput 更新状态入参
type AdminUpdateStatusInput struct {
	Status         string `json:"status" binding:"required"`
	StatusNote     string `json:"status_note"`
	ExpectedStatus string `json:"expected_status"`
}

var statusDisplayNames = map[string]string{
	models.FeedbackStatusPending:       "待受理",
	models.FeedbackStatusAccepted:      "已受理",
	models.FeedbackStatusWaitingUser:   "待用户补充",
	models.FeedbackStatusInvestigating: "定位中",
	models.FeedbackStatusFixing:        "修复中",
	models.FeedbackStatusTesting:       "测试中",
	models.FeedbackStatusResolved:      "已解决",
	models.FeedbackStatusClosed:        "已关闭",
}

// feedbackStatusTransitionAllowed 只允许沿着工单处理链路向前流转，
// waiting_user 由管理员请求补充信息进入，由用户补充后回到 accepted。
func feedbackStatusTransitionAllowed(oldStatus, newStatus string) bool {
	if oldStatus == newStatus {
		return true
	}
	switch oldStatus {
	case models.FeedbackStatusPending:
		return newStatus == models.FeedbackStatusAccepted
	case models.FeedbackStatusAccepted:
		return newStatus == models.FeedbackStatusInvestigating ||
			newStatus == models.FeedbackStatusFixing ||
			newStatus == models.FeedbackStatusTesting ||
			newStatus == models.FeedbackStatusResolved ||
			newStatus == models.FeedbackStatusWaitingUser
	case models.FeedbackStatusWaitingUser:
		return newStatus == models.FeedbackStatusAccepted
	case models.FeedbackStatusInvestigating:
		return newStatus == models.FeedbackStatusFixing ||
			newStatus == models.FeedbackStatusTesting ||
			newStatus == models.FeedbackStatusResolved ||
			newStatus == models.FeedbackStatusWaitingUser
	case models.FeedbackStatusFixing:
		return newStatus == models.FeedbackStatusTesting ||
			newStatus == models.FeedbackStatusResolved ||
			newStatus == models.FeedbackStatusWaitingUser
	case models.FeedbackStatusTesting:
		return newStatus == models.FeedbackStatusResolved ||
			newStatus == models.FeedbackStatusWaitingUser
	case models.FeedbackStatusResolved:
		return newStatus == models.FeedbackStatusClosed
	case models.FeedbackStatusClosed:
		return false
	default:
		return false
	}
}

var errFeedbackTicketTransitionInvalid = errors.New("非法的工单状态流转")

// AdminUpdateStatus 管理员更新工单处理进度
func (h *FeedbackTicketHandler) AdminUpdateStatus(c *gin.Context) {
	rawUID, _ := c.Get("user_id")
	adminID := rawUID.(uint)
	ticketID := c.Param("id")

	var input AdminUpdateStatusInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数不完整"})
		return
	}

	newStatus := strings.ToLower(strings.TrimSpace(input.Status))
	name, valid := statusDisplayNames[newStatus]
	if !valid {
		c.JSON(http.StatusBadRequest, gin.H{"error": "非法的工单状态"})
		return
	}

	now := time.Now()
	statusNote := strings.TrimSpace(input.StatusNote)
	expectedStatus := strings.ToLower(strings.TrimSpace(input.ExpectedStatus))
	var ticket models.FeedbackTicket
	var changed bool

	err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&ticket, ticketID).Error; err != nil {
			return err
		}
		if expectedStatus != "" && ticket.Status != expectedStatus {
			return errFeedbackTicketStateConflict
		}
		if !feedbackStatusTransitionAllowed(ticket.Status, newStatus) {
			return errFeedbackTicketTransitionInvalid
		}
		if ticket.Status == newStatus && ticket.StatusNote == statusNote {
			changed = false
			return nil
		}
		changed = true
		oldStatus := ticket.Status
		updates := map[string]interface{}{
			"status":            newStatus,
			"status_note":       statusNote,
			"updated_at":        now,
			"user_unread_count": gorm.Expr("user_unread_count + 1"),
		}

		if statusNote != "" {
			updates["latest_reply_snippet"] = feedbackSnippetForColumn(
				fmt.Sprintf("状态变更：%s · %s", name, statusNote), 255,
			)
		} else {
			updates["latest_reply_snippet"] = fmt.Sprintf("状态变更：%s", name)
		}

		switch newStatus {
		case models.FeedbackStatusResolved:
			if ticket.ResolvedAt == nil {
				updates["resolved_at"] = now
			}
			updates["closed_at"] = nil
		case models.FeedbackStatusClosed:
			if ticket.ResolvedAt == nil {
				updates["resolved_at"] = now
			}
			if ticket.ClosedAt == nil {
				updates["closed_at"] = now
			}
		default:
			updates["resolved_at"] = nil
			updates["closed_at"] = nil
		}

		if err := tx.Model(&ticket).Updates(updates).Error; err != nil {
			return err
		}

		// 记录状态变更历史
		history := models.FeedbackStatusHistory{
			TicketID:     ticket.ID,
			OperatorID:   adminID,
			OperatorType: "admin",
			OldStatus:    oldStatus,
			NewStatus:    newStatus,
			Note:         statusNote,
			CreatedAt:    now,
		}
		if err := tx.Create(&history).Error; err != nil {
			return err
		}

		// 创建状态变更消息
		msgContent := fmt.Sprintf("状态变更为：%s", name)
		if statusNote != "" {
			msgContent += fmt.Sprintf("（%s）", statusNote)
		}
		msg := models.FeedbackMessage{
			TicketID:      ticket.ID,
			SenderType:    "admin",
			SenderID:      adminID,
			MessageType:   models.FeedbackMsgStatusChange,
			Content:       msgContent,
			MetadataJSON:  fmt.Sprintf(`{"old_status":%q,"new_status":%q,"note":%q}`, oldStatus, newStatus, statusNote),
			VisibleToUser: true,
			CreatedAt:     now,
		}
		if err := tx.Create(&msg).Error; err != nil {
			return err
		}

		// 创建站内通知
		notif := models.Notification{
			UserID:    ticket.UserID,
			Type:      "feedback_update",
			Content:   fmt.Sprintf("工单 #%s %s", ticket.TicketNo, msgContent),
			RelatedID: ticket.ID,
			FromUID:   adminID,
			CreatedAt: now,
		}
		return tx.Create(&notif).Error
	})

	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "工单不存在"})
			return
		}
		if errors.Is(err, errFeedbackTicketStateConflict) {
			c.JSON(http.StatusConflict, gin.H{"code": "feedback_status_conflict", "error": err.Error()})
			return
		}
		if errors.Is(err, errFeedbackTicketTransitionInvalid) {
			c.JSON(http.StatusConflict, gin.H{"code": "feedback_invalid_transition", "error": err.Error()})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新状态失败"})
		return
	}
	if !changed {
		c.JSON(http.StatusOK, gin.H{
			"message":   "状态未变化",
			"ticket":    ticket,
			"no_change": true,
		})
		return
	}

	// 推送通知
	if h.notifier != nil {
		pushTitle := fmt.Sprintf("【反馈工单】状态更新：%s", name)
		pushContent := fmt.Sprintf("你的工单 #%s 已更新为：%s", ticket.TicketNo, name)
		if statusNote != "" {
			pushContent += " · " + statusNote
		}
		_ = h.notifier.Notify(ticket.UserID, pushTitle, pushContent, map[string]interface{}{
			"type":              "feedback_ticket",
			"ticket_id":         ticket.ID,
			"recipient_user_id": ticket.UserID,
		})
	}

	_ = h.db.Preload("User").Preload("AssigneeAdmin").First(&ticket, ticket.ID).Error

	c.JSON(http.StatusOK, gin.H{
		"message": "状态更新成功",
		"ticket":  ticket,
	})
}

// AdminRequestInfoInput 请求用户补充信息入参
type AdminRequestInfoInput struct {
	RequestedItems []string `json:"requested_items" binding:"required"`
	Comment        string   `json:"comment"`
	ExpectedStatus string   `json:"expected_status"`
}

// AdminRequestInfo 管理员结构化请求用户补充信息
func (h *FeedbackTicketHandler) AdminRequestInfo(c *gin.Context) {
	rawUID, _ := c.Get("user_id")
	adminID := rawUID.(uint)
	ticketID := c.Param("id")

	var input AdminRequestInfoInput
	if err := c.ShouldBindJSON(&input); err != nil || len(input.RequestedItems) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请至少选择一项需要用户补充的信息"})
		return
	}

	now := time.Now()
	newStatus := models.FeedbackStatusWaitingUser
	comment := strings.TrimSpace(input.Comment)
	expectedStatus := strings.ToLower(strings.TrimSpace(input.ExpectedStatus))
	var ticket models.FeedbackTicket

	metaBytes, _ := json.Marshal(map[string]interface{}{
		"requested_items": input.RequestedItems,
		"comment":         comment,
	})

	err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&ticket, ticketID).Error; err != nil {
			return err
		}
		if expectedStatus != "" && ticket.Status != expectedStatus {
			return errFeedbackTicketStateConflict
		}
		if !feedbackStatusTransitionAllowed(ticket.Status, newStatus) {
			return errFeedbackTicketTransitionInvalid
		}
		oldStatus := ticket.Status
		updates := map[string]interface{}{
			"status":               newStatus,
			"status_note":          "需要用户补充更多排查信息",
			"updated_at":           now,
			"user_unread_count":    gorm.Expr("user_unread_count + 1"),
			"latest_reply_snippet": "官方：需要你补充一些信息",
		}
		if err := tx.Model(&ticket).Updates(updates).Error; err != nil {
			return err
		}

		// 记录流转
		history := models.FeedbackStatusHistory{
			TicketID:     ticket.ID,
			OperatorID:   adminID,
			OperatorType: "admin",
			OldStatus:    oldStatus,
			NewStatus:    newStatus,
			Note:         "请求用户补充信息",
			CreatedAt:    now,
		}
		if err := tx.Create(&history).Error; err != nil {
			return err
		}

		// 创建 request_info 专用消息
		contentMsg := "开发人员需要你补充一些信息"
		if comment != "" {
			contentMsg = comment
		}
		msg := models.FeedbackMessage{
			TicketID:      ticket.ID,
			SenderType:    "admin",
			SenderID:      adminID,
			MessageType:   models.FeedbackMsgRequestInfo,
			Content:       contentMsg,
			MetadataJSON:  string(metaBytes),
			VisibleToUser: true,
			CreatedAt:     now,
		}
		if err := tx.Create(&msg).Error; err != nil {
			return err
		}

		// 站内通知
		notif := models.Notification{
			UserID:    ticket.UserID,
			Type:      "feedback_update",
			Content:   fmt.Sprintf("工单 #%s 需要你补充排查信息", ticket.TicketNo),
			RelatedID: ticket.ID,
			FromUID:   adminID,
			CreatedAt: now,
		}
		return tx.Create(&notif).Error
	})

	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "工单不存在"})
			return
		}
		if errors.Is(err, errFeedbackTicketStateConflict) {
			c.JSON(http.StatusConflict, gin.H{"code": "feedback_status_conflict", "error": err.Error()})
			return
		}
		if errors.Is(err, errFeedbackTicketTransitionInvalid) {
			c.JSON(http.StatusConflict, gin.H{"code": "feedback_invalid_transition", "error": err.Error()})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "操作失败，请稍后重试"})
		return
	}

	// 发送 JPush 通知
	if h.notifier != nil {
		pushTitle := "【反馈工单】开发人员需要你补充一些信息"
		pushContent := fmt.Sprintf("工单 #%s: 请提供相关截图或复现步骤以便排查", ticket.TicketNo)
		if comment != "" {
			pushContent = comment
		}
		_ = h.notifier.Notify(ticket.UserID, pushTitle, pushContent, map[string]interface{}{
			"type":              "feedback_ticket",
			"ticket_id":         ticket.ID,
			"recipient_user_id": ticket.UserID,
		})
	}

	_ = h.db.Preload("User").Preload("AssigneeAdmin").First(&ticket, ticket.ID).Error

	c.JSON(http.StatusOK, gin.H{
		"message": "已向用户发起补充信息请求",
		"ticket":  ticket,
	})
}

// AdminUpdateAssigneeInput 更新负责人与优先级入参
type AdminUpdateAssigneeInput struct {
	Priority        *string `json:"priority"`
	AssigneeAdminID *uint   `json:"assignee_admin_id"`
}

// AdminListAssignees 返回可分配工单的管理员，供管理端使用真实用户列表。
func (h *FeedbackTicketHandler) AdminListAssignees(c *gin.Context) {
	var assignees []models.User
	if err := h.db.Select("id", "student_id", "nickname", "avatar", "role").
		Where("role IN ?", []models.Role{models.RoleAdmin, models.RoleSuperAdmin}).
		Order("nickname ASC, id ASC").Find(&assignees).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取管理员列表失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"assignees": assignees})
}

// AdminUpdateAssignee 管理员设置负责人与优先级
func (h *FeedbackTicketHandler) AdminUpdateAssignee(c *gin.Context) {
	rawUID, _ := c.Get("user_id")
	adminID := rawUID.(uint)
	ticketID := c.Param("id")

	var input AdminUpdateAssigneeInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	var ticket models.FeedbackTicket
	var changed bool
	var auditDetail []string
	err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&ticket, ticketID).Error; err != nil {
			return err
		}

		updates := map[string]interface{}{}
		if input.Priority != nil {
			p := strings.ToUpper(strings.TrimSpace(*input.Priority))
			if p != models.FeedbackPriorityP0 && p != models.FeedbackPriorityP1 &&
				p != models.FeedbackPriorityP2 && p != models.FeedbackPriorityP3 {
				return fmt.Errorf("非法的工单优先级")
			}
			if ticket.Priority != p {
				updates["priority"] = p
				auditDetail = append(auditDetail, fmt.Sprintf("priority: %s -> %s", ticket.Priority, p))
			}
		}

		if input.AssigneeAdminID != nil {
			if *input.AssigneeAdminID == 0 {
				if ticket.AssigneeAdminID != nil {
					updates["assignee_admin_id"] = nil
					auditDetail = append(auditDetail, fmt.Sprintf("assignee_admin_id: %d -> none", *ticket.AssigneeAdminID))
				}
			} else {
				// 校验 admin 是否存在
				var admin models.User
				if err := tx.Where("id = ? AND role IN ?", *input.AssigneeAdminID, []models.Role{models.RoleAdmin, models.RoleSuperAdmin}).
					First(&admin).Error; err != nil {
					if errors.Is(err, gorm.ErrRecordNotFound) {
						return fmt.Errorf("指定的管理员不存在")
					}
					return err
				}
				if ticket.AssigneeAdminID == nil || *ticket.AssigneeAdminID != *input.AssigneeAdminID {
					oldAssignee := "none"
					if ticket.AssigneeAdminID != nil {
						oldAssignee = strconv.FormatUint(uint64(*ticket.AssigneeAdminID), 10)
					}
					updates["assignee_admin_id"] = *input.AssigneeAdminID
					auditDetail = append(auditDetail, fmt.Sprintf("assignee_admin_id: %s -> %d", oldAssignee, *input.AssigneeAdminID))
				}
			}
		}

		if len(updates) == 0 {
			return nil
		}
		changed = true
		updates["updated_at"] = time.Now()
		if err := tx.Model(&ticket).Updates(updates).Error; err != nil {
			return err
		}
		return tx.Create(&models.AdminActionLog{
			AdminID:    adminID,
			Action:     "update_feedback_assignment",
			TargetType: "feedback_ticket",
			TargetID:   ticket.ID,
			Detail:     strings.Join(auditDetail, "; "),
		}).Error
	})

	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "工单不存在"})
			return
		}
		if strings.Contains(err.Error(), "非法的工单优先级") || strings.Contains(err.Error(), "指定的管理员不存在") {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新工单设置失败"})
		return
	}
	if !changed {
		c.JSON(http.StatusOK, gin.H{"message": "设置未变化", "ticket": ticket, "no_change": true})
		return
	}

	_ = h.db.Preload("User").Preload("AssigneeAdmin").First(&ticket, ticket.ID).Error

	c.JSON(http.StatusOK, gin.H{
		"message": "更新成功",
		"ticket":  ticket,
	})
}
