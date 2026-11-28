package handlers

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gin-gonic/gin"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

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
	if c.Query("kind") == "ai" {
		h.getManagedAIs(c)
		return
	}

	search := strings.TrimSpace(c.Query("search"))

	role := c.Query("role")

	query := h.db.Model(&models.User{}).Where("COALESCE(account_status, '') <> ?", "bot")

	query = withAdminUserSearch(query, h.db, search)

	if role != "" {

		query = query.Where("role = ?", role)

	}

	var users []models.User
	if err := query.
		Select("id", "student_id", "student_verified_at", "nickname", "avatar", "role", "credit_score", "report_count", "edu_authorized", "edu_bound", "created_at").
		Order("created_at DESC").
		Find(&users).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取用户列表失败"})
		return
	}
	academicStudentIDs, err := loadAdminAcademicStudentIDs(h.db, users)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取用户教务身份失败"})
		return
	}
	academicConfigured, err := loadAdminAcademicConfigured(h.db, users)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取用户教务配置失败"})
		return
	}

	response := make([]AdminUserResponse, 0, len(users))
	for _, user := range users {
		response = append(response, adminUserResponse(user, adminStudentID(user, academicStudentIDs), academicConfigured[user.ID]))
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

	userID, err := strconv.ParseUint(userIDStr, 10, strconv.IntSize)

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

	userID, err := strconv.ParseUint(userIDStr, 10, strconv.IntSize)

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

	userID, err := strconv.ParseUint(userIDStr, 10, strconv.IntSize)

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

	userID, err := strconv.ParseUint(userIDStr, 10, strconv.IntSize)

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

	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if tx.Migrator().HasTable(&models.LotteryParticipant{}) && tx.Migrator().HasTable(&models.LotteryEvent{}) {
			ongoingEvents := tx.Model(&models.LotteryEvent{}).Select("id").Where("status = ?", models.LotteryStatusOngoing)
			if err := tx.Where("user_id = ? AND lottery_id IN (?)", user.ID, ongoingEvents).
				Delete(&models.LotteryParticipant{}).Error; err != nil {
				return err
			}
		}
		return tx.Delete(&user).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "用户已删除"})

}

// Statistics 系统统计

type Statistics struct {
	TotalUsers int64 `json:"total_users"`
	TotalAIs   int64 `json:"total_ais"`

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

	h.db.Model(&models.User{}).Where("COALESCE(account_status, '') <> ?", "bot").Count(&stats.TotalUsers)
	h.db.Model(&models.User{}).Where("account_status = ?", "bot").Count(&stats.TotalAIs)

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
			if errors.Is(err, gorm.ErrRecordNotFound) {
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
	// PrizeImage 选填，只接受本站 /upload 返回的 /uploads/ 路径；空串表示不展示奖品图。
	PrizeImage *string `json:"prize_image"`
}

type lotteryEventFields struct {
	title, prizeName, description, prizeImage string
	drawTime                                  time.Time
}

const (
	maxLotteryTitleRunes       = 100
	maxLotteryPrizeNameRunes   = 100
	maxLotteryDescriptionRunes = 2000
	maxLotteryPrizeImageLen    = 500
)

var errLotteryNotOngoing = errors.New("lottery is not ongoing")

func validateLotteryEventInput(input CreateLotteryEventInput) (lotteryEventFields, string) {
	f := lotteryEventFields{
		title:       strings.TrimSpace(input.Title),
		prizeName:   strings.TrimSpace(input.PrizeName),
		description: strings.TrimSpace(input.Description),
	}
	if input.PrizeImage != nil {
		f.prizeImage = strings.TrimSpace(*input.PrizeImage)
	}
	if f.title == "" || f.prizeName == "" {
		return f, "抽奖标题和奖品不能为空"
	}
	if utf8.RuneCountInString(f.title) > maxLotteryTitleRunes {
		return f, "抽奖标题不能超过 100 个字符"
	}
	if utf8.RuneCountInString(f.prizeName) > maxLotteryPrizeNameRunes {
		return f, "奖品名称不能超过 100 个字符"
	}
	if utf8.RuneCountInString(f.description) > maxLotteryDescriptionRunes {
		return f, "活动说明不能超过 2000 个字符"
	}
	if f.prizeImage != "" && (!strings.HasPrefix(f.prizeImage, "/uploads/") ||
		strings.Contains(f.prizeImage, "..") || len(f.prizeImage) > maxLotteryPrizeImageLen) {
		return f, "奖品图片无效，请重新上传"
	}

	parsedTime, err := time.Parse(time.RFC3339, strings.TrimSpace(input.DrawTime))
	if err != nil {
		return f, "开奖时间格式无效，请使用 RFC3339 格式"
	}
	if !parsedTime.After(time.Now()) {
		return f, "开奖时间必须晚于当前时间"
	}
	f.drawTime = parsedTime
	return f, ""
}

// claimLotteryPrizeImage 把奖品图升级为公开文件，避免被上传清理任务当作未引用文件回收。
func claimLotteryPrizeImage(tx *gorm.DB, operatorID uint, prizeImage string) error {
	if prizeImage == "" {
		return nil
	}
	ids, err := services.FileIDsByPublicPaths(tx, prizeImage)
	if err != nil {
		return err
	}
	if len(ids) != 1 {
		return services.ErrInvalidImageFileReference
	}
	return services.ClaimPublicImagePathsForUser(tx, operatorID, prizeImage)
}

// GetLotteryEvents 分页获取全部抽奖活动列表（含进行中、已开奖、已流拍、已取消）。
func (h *SuperAdminHandler) GetLotteryEvents(c *gin.Context) {
	page, pageSize := parseLotteryPagination(c, 20, 50)

	var total int64
	if err := h.db.Model(&models.LotteryEvent{}).Count(&total).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取抽奖列表失败"})
		return
	}

	var events []models.LotteryEvent
	if err := h.db.Preload("Winner").
		Order("CASE WHEN status = 0 THEN 0 ELSE 1 END ASC, created_at DESC, id DESC").
		Offset((page - 1) * pageSize).
		Limit(pageSize).
		Find(&events).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取抽奖列表失败"})
		return
	}

	eventIDs := make([]uint, len(events))
	for i, ev := range events {
		eventIDs[i] = ev.ID
	}
	counts, err := countParticipantsByLotteryIDs(h.db, eventIDs)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取抽奖列表失败"})
		return
	}

	items := make([]LotteryEventResponse, len(events))
	for i, ev := range events {
		items[i] = toLotteryEventResponse(ev, counts[ev.ID], false)
	}

	c.JSON(http.StatusOK, gin.H{
		"items":     items,
		"total":     total,
		"page":      page,
		"page_size": pageSize,
	})
}

// CreateLotteryEvent 发布抽奖活动。发布新活动时将旧的未开奖活动标记为已取消，保证前台只有一个进行中活动。
func (h *SuperAdminHandler) CreateLotteryEvent(c *gin.Context) {
	var input CreateLotteryEventInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请完整填写抽奖标题、奖品和开奖时间"})
		return
	}

	fields, errMsg := validateLotteryEventInput(input)
	if errMsg != "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": errMsg})
		return
	}

	operatorID := c.GetUint("user_id")
	var createdBy *uint
	if operatorID != 0 {
		createdBy = &operatorID
	}

	event := models.LotteryEvent{
		Title:       fields.title,
		Description: fields.description,
		PrizeName:   fields.prizeName,
		PrizeImage:  fields.prizeImage,
		DrawTime:    fields.drawTime,
		Status:      models.LotteryStatusOngoing,
		CreatedBy:   createdBy,
	}

	now := time.Now()
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if tx.Dialector.Name() == "postgres" {
			// 首次发布也没有可锁的旧活动；事务锁覆盖所有实例的发布入口。
			if err := tx.Exec("SELECT pg_advisory_xact_lock(hashtext(?))", "sylulive-lottery-publish").Error; err != nil {
				return err
			}
		}
		if err := tx.Model(&models.LotteryEvent{}).
			Where("status = ?", models.LotteryStatusOngoing).
			Updates(map[string]interface{}{
				"status":   models.LotteryStatusCancelled,
				"drawn_at": now,
			}).Error; err != nil {
			return err
		}
		if err := tx.Create(&event).Error; err != nil {
			return err
		}
		return claimLotteryPrizeImage(tx, operatorID, event.PrizeImage)
	}); err != nil {
		if errors.Is(err, services.ErrInvalidImageFileReference) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "奖品图片无效，请重新上传"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "发布抽奖失败"})
		return
	}

	recordLotteryAdminLog(
		h.db,
		c,
		"发布抽奖活动",
		fmt.Sprintf("抽奖 #%d（%s）", event.ID, event.Title),
		fmt.Sprintf("奖品：%s，开奖时间：%s", event.PrizeName, event.DrawTime.Format(time.RFC3339)),
	)

	c.JSON(http.StatusCreated, gin.H{
		"event":   toLotteryEventResponse(event, 0, false),
		"message": "抽奖已发布",
	})
}

// UpdateLotteryEvent 编辑进行中的抽奖活动。
func (h *SuperAdminHandler) UpdateLotteryEvent(c *gin.Context) {
	eventID, err := strconv.ParseUint(c.Param("id"), 10, strconv.IntSize)
	if err != nil || eventID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的抽奖ID"})
		return
	}

	var input CreateLotteryEventInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请完整填写抽奖标题、奖品和开奖时间"})
		return
	}

	fields, errMsg := validateLotteryEventInput(input)
	if errMsg != "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": errMsg})
		return
	}

	var event models.LotteryEvent
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&event, uint(eventID)).Error; err != nil {
			return err
		}
		if event.Status != models.LotteryStatusOngoing {
			return errLotteryNotOngoing
		}

		updates := map[string]interface{}{
			"title":       fields.title,
			"prize_name":  fields.prizeName,
			"description": fields.description,
			"draw_time":   fields.drawTime,
		}
		var oldImageIDs []uint
		if input.PrizeImage != nil {
			updates["prize_image"] = fields.prizeImage
			if event.PrizeImage != "" && event.PrizeImage != fields.prizeImage {
				var err error
				oldImageIDs, err = services.FileIDsByPublicPaths(tx, event.PrizeImage)
				if err != nil {
					return err
				}
			}
		}

		res := tx.Model(&models.LotteryEvent{}).
			Where("id = ? AND status = ?", event.ID, models.LotteryStatusOngoing).
			Updates(updates)
		if res.Error != nil {
			return res.Error
		}
		if res.RowsAffected == 0 {
			return errLotteryNotOngoing
		}
		if input.PrizeImage != nil {
			if err := claimLotteryPrizeImage(tx, c.GetUint("user_id"), fields.prizeImage); err != nil {
				return err
			}
		}
		if err := services.ReconcileFilePublicAccess(tx, oldImageIDs...); err != nil {
			return err
		}
		return tx.First(&event, event.ID).Error
	}); err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "抽奖活动不存在"})
		case errors.Is(err, errLotteryNotOngoing):
			c.JSON(http.StatusBadRequest, gin.H{"error": "该抽奖活动已结束，无法编辑", "code": "lottery_not_ongoing"})
		case errors.Is(err, services.ErrInvalidImageFileReference):
			c.JSON(http.StatusBadRequest, gin.H{"error": "奖品图片无效，请重新上传"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "更新抽奖活动失败"})
		}
		return
	}
	var participantCount int64
	_ = h.db.Model(&models.LotteryParticipant{}).Where("lottery_id = ?", event.ID).Count(&participantCount).Error

	recordLotteryAdminLog(
		h.db,
		c,
		"编辑抽奖活动",
		fmt.Sprintf("抽奖 #%d（%s）", event.ID, event.Title),
		fmt.Sprintf("奖品：%s，开奖时间：%s", event.PrizeName, event.DrawTime.Format(time.RFC3339)),
	)

	c.JSON(http.StatusOK, gin.H{
		"event":   toLotteryEventResponse(event, participantCount, false),
		"message": "抽奖活动已更新",
	})
}

// DeleteLotteryEvent 删除抽奖活动，同时清理参与记录。
func (h *SuperAdminHandler) DeleteLotteryEvent(c *gin.Context) {
	eventID, err := strconv.ParseUint(c.Param("id"), 10, strconv.IntSize)
	if err != nil || eventID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的抽奖ID"})
		return
	}

	var deletedTitle string
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		var event models.LotteryEvent
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&event, eventID).Error; err != nil {
			return err
		}
		deletedTitle = event.Title
		oldImageIDs, err := services.FileIDsByPublicPaths(tx, event.PrizeImage)
		if err != nil {
			return err
		}
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
		return services.ReconcileFilePublicAccess(tx, oldImageIDs...)
	}); err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "抽奖活动不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除抽奖失败"})
		return
	}

	recordLotteryAdminLog(
		h.db,
		c,
		"删除抽奖活动",
		fmt.Sprintf("抽奖 #%d（%s）", eventID, deletedTitle),
		"已删除活动及其全部参与记录",
	)

	c.JSON(http.StatusOK, gin.H{"message": "抽奖已删除"})
}

// GetLotteryParticipants 获取指定活动或当前抽奖活动的参与者（支持分页并裁剪用户敏感字段）。
func (h *SuperAdminHandler) GetLotteryParticipants(c *gin.Context) {
	var event models.LotteryEvent
	var err error
	if eventIDStr := strings.TrimSpace(c.Query("event_id")); eventIDStr != "" {
		eventID, parseErr := strconv.ParseUint(eventIDStr, 10, strconv.IntSize)
		if parseErr != nil || eventID == 0 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效的抽奖ID"})
			return
		}
		err = h.db.Preload("Winner").First(&event, uint(eventID)).Error
	} else {
		event, err = findCurrentLotteryEvent(h.db, true)
	}
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "暂无抽奖活动", "code": "lottery_not_found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取抽奖活动失败"})
		return
	}

	page, pageSize := parseLotteryPagination(c, 50, 100)
	var total int64
	if err := h.db.Model(&models.LotteryParticipant{}).Where("lottery_id = ?", event.ID).Count(&total).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取参与者列表失败"})
		return
	}

	var participants []models.LotteryParticipant
	query := h.db.Where("lottery_id = ?", event.ID).Preload("User")
	if event.WinnerID != nil {
		query = query.Clauses(clause.OrderBy{Expression: clause.Expr{
			SQL:  "CASE WHEN user_id = ? THEN 0 ELSE 1 END, created_at DESC, id DESC",
			Vars: []any{*event.WinnerID},
		}})
	} else {
		query = query.Order("created_at DESC, id DESC")
	}
	if err := query.
		Offset((page - 1) * pageSize).
		Limit(pageSize).
		Find(&participants).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取参与者列表失败"})
		return
	}

	items := make([]LotteryParticipantResponse, len(participants))
	for i, p := range participants {
		level := services.CalculateUserLevel(p.User.Exp)
		currentWeight := p.Weight
		if event.Status == models.LotteryStatusOngoing {
			currentWeight = services.CalculateLotteryWeightByLevel(p.User.Exp)
		}
		nickname := p.User.Nickname
		if nickname == "" {
			nickname = "已注销/已删除用户"
		}
		items[i] = LotteryParticipantResponse{
			ID:            p.ID,
			CreatedAt:     p.CreatedAt,
			LotteryID:     p.LotteryID,
			UserID:        p.UserID,
			Weight:        p.Weight,
			CurrentWeight: currentWeight,
			User: LotteryParticipantUserResponse{
				ID:       p.UserID,
				Nickname: nickname,
				Avatar:   p.User.Avatar,
				Exp:      p.User.Exp,
				Level:    level,
			},
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"event":        toLotteryEventResponse(event, total, false),
		"participants": items,
		"total":        total,
		"page":         page,
		"page_size":    pageSize,
	})
}

// KickLotteryParticipant 踢出参与者（仅进行中活动可操作，踢出后用户可重新参与）。
func (h *SuperAdminHandler) KickLotteryParticipant(c *gin.Context) {
	eventIDStr := c.Param("event_id")
	userIDStr := c.Param("user_id")

	eventID, err1 := strconv.ParseUint(eventIDStr, 10, strconv.IntSize)
	userID, err2 := strconv.ParseUint(userIDStr, 10, strconv.IntSize)

	if err1 != nil || err2 != nil || eventID == 0 || userID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的参数"})
		return
	}

	var event models.LotteryEvent
	var removed int64
	err := h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&event, uint(eventID)).Error; err != nil {
			return err
		}
		if event.Status != models.LotteryStatusOngoing {
			return nil
		}
		result := tx.Where("lottery_id = ? AND user_id = ?", eventID, userID).Delete(&models.LotteryParticipant{})
		removed = result.RowsAffected
		return result.Error
	})
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "抽奖活动不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询抽奖活动失败"})
		return
	}
	if event.Status != models.LotteryStatusOngoing {
		c.JSON(http.StatusBadRequest, gin.H{"error": "活动已结束，无法踢出参与者", "code": "lottery_not_ongoing"})
		return
	}

	if removed == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "该用户未参与该抽奖"})
		return
	}

	recordLotteryAdminLog(
		h.db,
		c,
		"踢出抽奖参与者",
		fmt.Sprintf("抽奖 #%d / 用户 #%d", eventID, userID),
		fmt.Sprintf("从活动【%s】移除参与记录", event.Title),
	)

	c.JSON(http.StatusOK, gin.H{"message": "已成功踢出"})
}
