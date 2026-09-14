package handlers

import (
	"encoding/json"
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
	if err := query.Order("updated_at DESC").Offset(offset).Limit(limit).Find(&tickets).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询工单失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"total":   total,
		"page":    page,
		"limit":   limit,
		"tickets": tickets,
	})
}

// AdminGetStats 管理员获取工单数据概览
func (h *FeedbackTicketHandler) AdminGetStats(c *gin.Context) {
	var pendingCount int64
	var waitingUserCount int64
	var testingCount int64
	var unviewedCount int64
	var totalUnresolved int64

	_ = h.db.Model(&models.FeedbackTicket{}).Where("status = ?", models.FeedbackStatusPending).Count(&pendingCount).Error
	_ = h.db.Model(&models.FeedbackTicket{}).Where("status = ?", models.FeedbackStatusWaitingUser).Count(&waitingUserCount).Error
	_ = h.db.Model(&models.FeedbackTicket{}).Where("status = ?", models.FeedbackStatusTesting).Count(&testingCount).Error
	_ = h.db.Model(&models.FeedbackTicket{}).Where("admin_viewed = ?", false).Count(&unviewedCount).Error
	_ = h.db.Model(&models.FeedbackTicket{}).
		Where("status NOT IN ?", []string{models.FeedbackStatusResolved, models.FeedbackStatusClosed}).
		Count(&totalUnresolved).Error

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

	now := time.Now()
	// 若管理员未曾查看，标记为已查看
	if !ticket.AdminViewed {
		updates := map[string]interface{}{
			"admin_viewed": true,
		}
		if ticket.AdminFirstViewedAt == nil {
			updates["admin_first_viewed_at"] = now
			ticket.AdminFirstViewedAt = &now
		}
		_ = h.db.Model(&ticket).Updates(updates).Error
		ticket.AdminViewed = true
	}

	// 读取全部消息（管理员端包含 internal_note）
	var messages []models.FeedbackMessage
	if err := h.db.Where("ticket_id = ?", ticket.ID).
		Preload("Attachments.File").
		Preload("Sender").
		Order("created_at ASC").
		Find(&messages).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取消息失败"})
		return
	}

	// 初始附件
	var attachments []models.FeedbackAttachment
	_ = h.db.Where("ticket_id = ? AND (message_id IS NULL OR message_id = 0)", ticket.ID).
		Preload("File").
		Find(&attachments).Error
	ticket.Attachments = attachments

	// 状态变更记录
	var history []models.FeedbackStatusHistory
	_ = h.db.Where("ticket_id = ?", ticket.ID).Order("created_at ASC").Find(&history).Error

	c.JSON(http.StatusOK, gin.H{
		"ticket":   ticket,
		"messages": messages,
		"history":  history,
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

	var ticket models.FeedbackTicket
	if err := h.db.First(&ticket, ticketID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "工单不存在"})
		return
	}

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

	now := time.Now()
	msgType := models.FeedbackMsgText
	if !input.VisibleToUser {
		msgType = models.FeedbackMsgInternalNote
	}

	msg := models.FeedbackMessage{
		TicketID:      ticket.ID,
		SenderType:    "admin",
		SenderID:      adminID,
		MessageType:   msgType,
		Content:       input.Content,
		VisibleToUser: input.VisibleToUser,
		CreatedAt:     now,
	}

	err := h.db.Transaction(func(tx *gorm.DB) error {
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

			// 创建站内通知
			notif := models.Notification{
				UserID:    ticket.UserID,
				Type:      "feedback_update",
				Content:   fmt.Sprintf("工单 #%s 收到管理员新回复：%s", ticket.TicketNo, snippet),
				RelatedID: ticket.ID,
				FromUID:   adminID,
				CreatedAt: now,
			}
			_ = tx.Create(&notif).Error
		}

		return tx.Model(&ticket).Updates(ticketUpdates).Error
	})

	if err != nil {
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
			"type":               "feedback_ticket",
			"ticket_id":          ticket.ID,
			"recipient_user_id": ticket.UserID,
		})
	}

	_ = h.db.Preload("Attachments.File").Preload("Sender").First(&msg, msg.ID).Error

	c.JSON(http.StatusOK, gin.H{
		"message": msg,
	})
}

// AdminUpdateStatusInput 更新状态入参
type AdminUpdateStatusInput struct {
	Status     string `json:"status" binding:"required"`
	StatusNote string `json:"status_note"`
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

// AdminUpdateStatus 管理员更新工单处理进度
func (h *FeedbackTicketHandler) AdminUpdateStatus(c *gin.Context) {
	rawUID, _ := c.Get("user_id")
	adminID := rawUID.(uint)
	ticketID := c.Param("id")

	var ticket models.FeedbackTicket
	if err := h.db.First(&ticket, ticketID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "工单不存在"})
		return
	}

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
	oldStatus := ticket.Status
	statusNote := strings.TrimSpace(input.StatusNote)

	err := h.db.Transaction(func(tx *gorm.DB) error {
		var lockedTicket models.FeedbackTicket
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			First(&lockedTicket, ticketID).Error; err != nil {
			return err
		}
		ticket = lockedTicket
		oldStatus = lockedTicket.Status
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

		if newStatus == models.FeedbackStatusResolved && ticket.ResolvedAt == nil {
			updates["resolved_at"] = now
		}
		if newStatus == models.FeedbackStatusClosed && ticket.ClosedAt == nil {
			updates["closed_at"] = now
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
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新状态失败"})
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
			"type":               "feedback_ticket",
			"ticket_id":          ticket.ID,
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
}

// AdminRequestInfo 管理员结构化请求用户补充信息
func (h *FeedbackTicketHandler) AdminRequestInfo(c *gin.Context) {
	rawUID, _ := c.Get("user_id")
	adminID := rawUID.(uint)
	ticketID := c.Param("id")

	var ticket models.FeedbackTicket
	if err := h.db.First(&ticket, ticketID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "工单不存在"})
		return
	}

	var input AdminRequestInfoInput
	if err := c.ShouldBindJSON(&input); err != nil || len(input.RequestedItems) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请至少选择一项需要用户补充的信息"})
		return
	}

	now := time.Now()
	oldStatus := ticket.Status
	newStatus := models.FeedbackStatusWaitingUser
	comment := strings.TrimSpace(input.Comment)

	metaBytes, _ := json.Marshal(map[string]interface{}{
		"requested_items": input.RequestedItems,
		"comment":         comment,
	})

	err := h.db.Transaction(func(tx *gorm.DB) error {
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
			"type":               "feedback_ticket",
			"ticket_id":          ticket.ID,
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

// AdminUpdateAssignee 管理员设置负责人与优先级
func (h *FeedbackTicketHandler) AdminUpdateAssignee(c *gin.Context) {
	ticketID := c.Param("id")

	var ticket models.FeedbackTicket
	if err := h.db.First(&ticket, ticketID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "工单不存在"})
		return
	}

	var input AdminUpdateAssigneeInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	updates := map[string]interface{}{
		"updated_at": time.Now(),
	}

	if input.Priority != nil {
		p := strings.ToUpper(strings.TrimSpace(*input.Priority))
		if p == "P0" || p == "P1" || p == "P2" || p == "P3" {
			updates["priority"] = p
		}
	}

	if input.AssigneeAdminID != nil {
		if *input.AssigneeAdminID == 0 {
			updates["assignee_admin_id"] = nil
		} else {
			// 校验 admin 是否存在
			var admin models.User
			if err := h.db.Where("id = ? AND role IN ?", *input.AssigneeAdminID, []models.Role{models.RoleAdmin, models.RoleSuperAdmin}).
				First(&admin).Error; err == nil {
				updates["assignee_admin_id"] = *input.AssigneeAdminID
			}
		}
	}

	if err := h.db.Model(&ticket).Updates(updates).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新工单设置失败"})
		return
	}

	_ = h.db.Preload("User").Preload("AssigneeAdmin").First(&ticket, ticket.ID).Error

	c.JSON(http.StatusOK, gin.H{
		"message": "更新成功",
		"ticket":  ticket,
	})
}
