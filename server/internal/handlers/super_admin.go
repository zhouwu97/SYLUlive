package handlers

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"time"

	"github.com/gin-gonic/gin"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// SuperAdminHandler 超级管理员处理器

type SuperAdminHandler struct {
	db                *gorm.DB
	emailVerification *services.EmailVerificationService
}

// NewSuperAdminHandler 创建超级管理员处理器

func NewSuperAdminHandler(db *gorm.DB) *SuperAdminHandler {
	return &SuperAdminHandler{db: db}
}

// NewSuperAdminHandlerWithEmailVerification 创建支持一次性邮箱重置挑战的处理器。
func NewSuperAdminHandlerWithEmailVerification(db *gorm.DB, emailVerification *services.EmailVerificationService) *SuperAdminHandler {
	return &SuperAdminHandler{db: db, emailVerification: emailVerification}
}

// GetUsers 获取所有用户

func (h *SuperAdminHandler) GetUsers(c *gin.Context) {

	search := strings.TrimSpace(c.Query("search"))

	role := c.Query("role")

	query := h.db.Model(&models.User{})

	if search != "" {
		like := "%" + strings.ToLower(search) + "%"
		if userID, err := strconv.ParseUint(search, 10, 64); err == nil {
			query = query.Where(
				"id = ? OR LOWER(student_id) LIKE ? OR LOWER(nickname) LIKE ?",
				userID,
				like,
				like,
			)
		} else {
			query = query.Where(
				"LOWER(student_id) LIKE ? OR LOWER(nickname) LIKE ?",
				like,
				like,
			)
		}
	}

	if role != "" {

		query = query.Where("role = ?", role)

	}

	var users []models.User
	if err := query.
		Select("id", "student_id", "nickname", "avatar", "role", "credit_score", "report_count", "edu_bound", "created_at").
		Order("created_at DESC").
		Find(&users).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取用户列表失败"})
		return
	}

	response := make([]AdminUserResponse, 0, len(users))
	for _, user := range users {
		response = append(response, adminUserResponse(user))
	}
	c.JSON(http.StatusOK, response)

}

// UpdateUserRoleInput 更新用户角色输入

type UpdateUserRoleInput struct {
	Role string `json:"role" binding:"required"`
}

// UpdateUserRole 更新用户角色

func (h *SuperAdminHandler) UpdateUserRole(c *gin.Context) {

	userIDStr := c.Param("id")

	userID, err := strconv.ParseUint(userIDStr, 10, 64)

	if err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})

		return

	}

	var user models.User

	if err := h.db.First(&user, userID).Error; err != nil {

		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})

		return

	}

	// 超级管理员不能被降级

	if user.Role == models.RoleSuperAdmin {

		c.JSON(http.StatusForbidden, gin.H{"error": "不能修改超级管理员的角色"})

		return

	}

	var input UpdateUserRoleInput

	if err := c.ShouldBindJSON(&input); err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})

		return

	}

	if input.Role != string(models.RoleUser) && input.Role != string(models.RoleAdmin) {

		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的角色"})

		return

	}

	// 防止权限提升：不能把自己提升为超级管理员

	currentUserID := c.GetUint("user_id")

	if currentUserID == uint(userID) && input.Role == string(models.RoleSuperAdmin) {

		c.JSON(http.StatusForbidden, gin.H{"error": "不能提升自己的权限"})

		return

	}

	if err := services.UpdateUserRoleAndInvalidateToken(h.db, user.ID, models.Role(input.Role)); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "角色更新成功"})

}

// UpdateUserCreditInput 更新用户诚信度输入

type UpdateUserCreditInput struct {
	CreditScore int `json:"credit_score" binding:"required,min=0,max=100"`
}

// UpdateUserCredit 更新用户诚信度

func (h *SuperAdminHandler) UpdateUserCredit(c *gin.Context) {

	userIDStr := c.Param("id")

	userID, err := strconv.ParseUint(userIDStr, 10, 64)

	if err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})

		return

	}

	var input UpdateUserCreditInput

	if err := c.ShouldBindJSON(&input); err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})

		return

	}

	if err := h.db.Model(&models.User{}).Where("id = ?", userID).Update("credit_score", input.CreditScore).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "诚信度更新成功"})

}

// ResetUserPassword 向用户已验证邮箱发送一次性密码重置验证码。

func (h *SuperAdminHandler) ResetUserPassword(c *gin.Context) {

	userIDStr := c.Param("id")

	userID, err := strconv.ParseUint(userIDStr, 10, 64)

	if err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})

		return

	}

	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	if user.Email == "" || user.EmailVerifiedAt == nil {
		c.JSON(http.StatusConflict, gin.H{"error": "该用户没有已验证邮箱，无法发起密码重置"})
		return
	}
	if h.emailVerification == nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{"error": "服务器未配置邮件服务"})
		return
	}
	if err := h.emailVerification.Request(user.Email, models.EmailVerificationPurposeResetPassword, &user.ID, c.ClientIP()); err != nil {
		writeEmailVerificationError(c, err)
		return
	}
	_ = h.db.Create(&models.AccountSecurityAuditLog{UserID: user.ID, Action: "admin_password_reset_challenge_requested"}).Error

	c.JSON(http.StatusOK, gin.H{"message": "密码重置验证码已发送至用户已验证邮箱"})

}

// DeleteUser 删除用户

func (h *SuperAdminHandler) DeleteUser(c *gin.Context) {

	userIDStr := c.Param("id")

	userID, err := strconv.ParseUint(userIDStr, 10, 64)

	if err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})

		return

	}

	var user models.User

	if err := h.db.First(&user, userID).Error; err != nil {

		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})

		return

	}

	// 超级管理员不能删除

	if user.Role == models.RoleSuperAdmin {

		c.JSON(http.StatusForbidden, gin.H{"error": "不能删除超级管理员"})

		return

	}

	if err := h.db.Delete(&user).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "用户已删除"})

}

// Statistics 系统统计

type Statistics struct {
	TotalUsers int64 `json:"total_users"`

	TotalPosts int64 `json:"total_posts"`

	TotalReports int64 `json:"total_reports"`

	PendingReports int64 `json:"pending_reports"`

	TotalAppeals int64 `json:"total_appeals"`

	PendingAppeals int64 `json:"pending_appeals"`

	AdminCount int64 `json:"admin_count"`

	SuperAdminCount int64 `json:"super_admin_count"`
}

// GetStatistics 获取系统统计

func (h *SuperAdminHandler) GetStatistics(c *gin.Context) {

	var stats Statistics

	h.db.Model(&models.User{}).Count(&stats.TotalUsers)

	h.db.Model(&models.Post{}).Count(&stats.TotalPosts)

	h.db.Model(&models.Report{}).Count(&stats.TotalReports)

	h.db.Model(&models.Report{}).Where("status = ?", models.ReportStatusPending).Count(&stats.PendingReports)

	h.db.Model(&models.Appeal{}).Count(&stats.TotalAppeals)

	h.db.Model(&models.Appeal{}).Where("status = ?", models.AppealStatusPending).Count(&stats.PendingAppeals)

	h.db.Model(&models.User{}).Where("role = ?", models.RoleAdmin).Count(&stats.AdminCount)

	h.db.Model(&models.User{}).Where("role = ?", models.RoleSuperAdmin).Count(&stats.SuperAdminCount)

	c.JSON(http.StatusOK, stats)

}

// AdminLogItem 管理员日志项（含经验信息）

type AdminLogItem struct {
	ID uint `json:"id"`

	AdminID uint `json:"admin_id"`

	AdminName string `json:"admin_name"`

	Action string `json:"action"`

	Target string `json:"target"`

	Detail string `json:"detail"`

	CreatedAt time.Time `json:"created_at"`

	AdminExp int `json:"admin_exp"` // 当前管理员经验

	AdminRole string `json:"admin_role"` // 管理员角色

}

// GetAdminLogs 获取管理员操作日志（含经验信息）

func (h *SuperAdminHandler) GetAdminLogs(c *gin.Context) {

	var logs []models.AdminLog
	if err := h.db.Preload("Admin").Order("created_at DESC").Limit(200).Find(&logs).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取管理日志失败"})
		return
	}

	result := make([]AdminLogItem, len(logs))

	for i, log := range logs {

		result[i] = AdminLogItem{

			ID: log.ID,

			AdminID: log.AdminID,

			AdminName: log.AdminName,

			Action: log.Action,

			Target: log.Target,

			Detail: log.Detail,

			CreatedAt: log.CreatedAt,

			AdminExp: log.Admin.AdminExp,

			AdminRole: string(log.Admin.Role),
		}

	}

	c.JSON(http.StatusOK, result)

}

// RevokeAdminExpInput 追回管理员经验输入

type RevokeAdminExpInput struct {
	AdminID uint `json:"admin_id" binding:"required"`

	Amount int `json:"amount" binding:"required,min=1"`

	Reason string `json:"reason"`
}

// RevokeAdminExp 追回管理员经验

func (h *SuperAdminHandler) RevokeAdminExp(c *gin.Context) {

	operatorID, _ := c.Get("user_id")

	var input RevokeAdminExpInput

	if err := c.ShouldBindJSON(&input); err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})

		return

	}

	var target models.User

	if err := h.db.First(&target, input.AdminID).Error; err != nil {

		c.JSON(http.StatusNotFound, gin.H{"error": "管理员不存在"})

		return

	}

	if target.Role != "admin" && target.Role != "super_admin" {

		c.JSON(http.StatusBadRequest, gin.H{"error": "目标用户不是管理员"})

		return

	}

	// 不能追回超级管理员的经验（除非操作者也是超级管理员）

	if target.Role == "super_admin" {

		var operator models.User

		if err := h.db.Select("role").First(&operator, operatorID).Error; err != nil {
			if err == gorm.ErrRecordNotFound {
				c.JSON(http.StatusForbidden, gin.H{"error": "无权追回超级管理员的经验"})
			} else {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库错误"})
			}
			return
		}

		if operator.Role != "super_admin" {

			c.JSON(http.StatusForbidden, gin.H{"error": "无权追回超级管理员的经验"})

			return

		}

	}

	// 扣减经验（不低于0）

	newExp := target.AdminExp - input.Amount

	if newExp < 0 {

		newExp = 0

	}

	if err := h.db.Model(&target).Update("admin_exp", newExp).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	// 记录操作日志

	reason := input.Reason

	if reason == "" {

		reason = "追回经验"

	}

	var operator models.User

	if err := h.db.Select("nickname").First(&operator, operatorID).Error; err != nil {
		operator.Nickname = "Unknown Admin"
	}

	h.db.Create(&models.AdminLog{

		AdminID: operatorID.(uint),

		AdminName: operator.Nickname,

		Action: "追回管理员经验",

		Target: target.Nickname,

		Detail: fmt.Sprintf("追回 %d 经验（原因: %s），剩余 %d", input.Amount, reason, newExp),
	})

	c.JSON(http.StatusOK, gin.H{

		"message": "经验已追回",

		"admin_id": input.AdminID,

		"revoked": input.Amount,

		"remaining": newExp,
	})

}

type CreateLotteryEventInput struct {
	Title       string `json:"title" binding:"required"`
	Description string `json:"description"`
	PrizeName   string `json:"prize_name" binding:"required"`
	DrawTime    string `json:"draw_time" binding:"required"`
}

// CreateLotteryEvent 发布抽奖活动。发布新活动时会结束旧的未开奖活动，保证前台只有一个当前活动。
func (h *SuperAdminHandler) CreateLotteryEvent(c *gin.Context) {
	var input CreateLotteryEventInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请完整填写抽奖标题、奖品和开奖时间"})
		return
	}

	title := strings.TrimSpace(input.Title)
	prizeName := strings.TrimSpace(input.PrizeName)
	description := strings.TrimSpace(input.Description)
	if title == "" || prizeName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "抽奖标题和奖品不能为空"})
		return
	}

	drawTime, err := time.Parse(time.RFC3339, strings.TrimSpace(input.DrawTime))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "开奖时间格式无效"})
		return
	}
	if !drawTime.After(time.Now()) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "开奖时间必须晚于当前时间"})
		return
	}

	event := models.LotteryEvent{
		Title:       title,
		Description: description,
		PrizeName:   prizeName,
		DrawTime:    drawTime,
		Status:      0,
	}

	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.LotteryEvent{}).
			Where("status = ?", 0).
			Update("status", 1).Error; err != nil {
			return err
		}
		return tx.Create(&event).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "发布抽奖失败"})
		return
	}

	c.JSON(http.StatusCreated, gin.H{
		"event":   event,
		"message": "抽奖已发布",
	})
}

// DeleteLotteryEvent 删除抽奖活动，同时清理参与记录。
func (h *SuperAdminHandler) DeleteLotteryEvent(c *gin.Context) {
	eventID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || eventID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的抽奖ID"})
		return
	}

	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("lottery_id = ?", eventID).Delete(&models.LotteryParticipant{}).Error; err != nil {
			return err
		}
		result := tx.Delete(&models.LotteryEvent{}, eventID)
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected == 0 {
			return gorm.ErrRecordNotFound
		}
		return nil
	}); err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, gin.H{"error": "抽奖活动不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除抽奖失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "抽奖已删除"})
}

// GetLotteryParticipants 获取当前抽奖的参与者
func (h *SuperAdminHandler) GetLotteryParticipants(c *gin.Context) {
	var event models.LotteryEvent
	err := h.db.Order("status ASC, created_at DESC").First(&event).Error
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "暂无抽奖活动"})
		return
	}

	var participants []models.LotteryParticipant
	if err := h.db.Where("lottery_id = ?", event.ID).Preload("User").Find(&participants).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取参与者列表失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"event":        event,
		"participants": participants,
	})
}

// KickLotteryParticipant 踢出参与者
func (h *SuperAdminHandler) KickLotteryParticipant(c *gin.Context) {
	eventIDStr := c.Param("event_id")
	userIDStr := c.Param("user_id")

	eventID, err1 := strconv.ParseUint(eventIDStr, 10, 64)
	userID, err2 := strconv.ParseUint(userIDStr, 10, 64)

	if err1 != nil || err2 != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的参数"})
		return
	}

	result := h.db.Where("lottery_id = ? AND user_id = ?", eventID, userID).Delete(&models.LotteryParticipant{})
	if result.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "踢出失败"})
		return
	}

	if result.RowsAffected == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "该用户未参与该抽奖"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "已成功踢出"})
}
