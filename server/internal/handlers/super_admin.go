package handlers

import (
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"

	"time"

	"github.com/gin-gonic/gin"

	"golang.org/x/crypto/bcrypt"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// SuperAdminHandler 超级管理员处理器

type SuperAdminHandler struct {
	db *gorm.DB
}

// NewSuperAdminHandler 创建超级管理员处理器

func NewSuperAdminHandler(db *gorm.DB) *SuperAdminHandler {

	return &SuperAdminHandler{db: db}

}

// GetUsers 获取所有用户

func (h *SuperAdminHandler) GetUsers(c *gin.Context) {

	search := c.Query("search")

	role := c.Query("role")

	query := h.db.Model(&models.User{})

	if search != "" {

		query = query.Where("student_id LIKE ? OR nickname LIKE ?", "%"+search+"%", "%"+search+"%")

	}

	if role != "" {

		query = query.Where("role = ?", role)

	}

	var users []models.User
	if err := query.Order("created_at DESC").Find(&users).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取用户列表失败"})
		return
	}

	c.JSON(http.StatusOK, users)

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

// ResetUserPassword 重置用户密码

func (h *SuperAdminHandler) ResetUserPassword(c *gin.Context) {

	userIDStr := c.Param("id")

	userID, err := strconv.ParseUint(userIDStr, 10, 64)

	if err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})

		return

	}

	defaultPassword := os.Getenv("DEFAULT_RESET_PASSWORD")
	if defaultPassword == "" {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "系统未配置默认重置密码，请联系管理员"})
		return
	}

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(defaultPassword), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码加密失败"})
		return
	}

	h.db.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{"password_hash": string(hashedPassword), "token_version": gorm.Expr("token_version + 1")})

	c.JSON(http.StatusOK, gin.H{"message": "密码已重置为系统默认密码"})

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

// AiConfigInput AI 全局配置输入
type AiConfigInput struct {
	BaseURL               string `json:"base_url" binding:"required"`
	APIKey                string `json:"api_key" binding:"required"`
	ModelName             string `json:"model_name" binding:"required"`
	InputPricePer1KCents  int    `json:"input_price_per_1k_cents"`
	OutputPricePer1KCents int    `json:"output_price_per_1k_cents"`
	CacheHitPriceCents    int    `json:"cache_hit_price_cents"`
	MinLivePriceCents     int    `json:"min_live_price_cents"`
}

// GetAiConfig 获取全局 AI 配置
func (h *SuperAdminHandler) GetAiConfig(c *gin.Context) {
	configKeys := []string{
		"ai_base_url",
		"ai_api_key",
		"ai_model_name",
		"ai_input_price_per_1m_cents",
		"ai_output_price_per_1m_cents",
		"ai_input_price_per_1k_cents",
		"ai_output_price_per_1k_cents",
		"ai_cache_hit_price_cents",
		"ai_min_live_price_cents",
	}
	var configs []models.SystemConfig
	if err := h.db.Where("config_key IN ?", configKeys).Find(&configs).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取配置失败"})
		return
	}

	configMap := make(map[string]string)
	for _, conf := range configs {
		configMap[conf.ConfigKey] = conf.ConfigValue
	}

	inputPricePer1K := configMap["ai_input_price_per_1k_cents"]
	if strings.TrimSpace(inputPricePer1K) == "" {
		if legacy := strings.TrimSpace(configMap["ai_input_price_per_1m_cents"]); legacy != "" {
			if value, err := strconv.Atoi(legacy); err == nil && value > 0 {
				inputPricePer1K = strconv.Itoa((value + 999) / 1000)
			}
		}
	}
	if strings.TrimSpace(inputPricePer1K) == "" || inputPricePer1K == "0" {
		inputPricePer1K = "2"
	}

	outputPricePer1K := configMap["ai_output_price_per_1k_cents"]
	if strings.TrimSpace(outputPricePer1K) == "" {
		if legacy := strings.TrimSpace(configMap["ai_output_price_per_1m_cents"]); legacy != "" {
			if value, err := strconv.Atoi(legacy); err == nil && value > 0 {
				outputPricePer1K = strconv.Itoa((value + 999) / 1000)
			}
		}
	}
	if strings.TrimSpace(outputPricePer1K) == "" || outputPricePer1K == "0" {
		outputPricePer1K = "4"
	}

	c.JSON(http.StatusOK, gin.H{
		"base_url":                  configMap["ai_base_url"],
		"api_key":                   configMap["ai_api_key"],
		"model_name":                configMap["ai_model_name"],
		"input_price_per_1k_cents":  inputPricePer1K,
		"output_price_per_1k_cents": outputPricePer1K,
		"cache_hit_price_cents":     configMap["ai_cache_hit_price_cents"],
		"min_live_price_cents":      configMap["ai_min_live_price_cents"],
	})
}

// UpdateAiConfig 更新全局 AI 配置
func (h *SuperAdminHandler) UpdateAiConfig(c *gin.Context) {
	var input AiConfigInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 开启事务更新三个键值对
	err := h.db.Transaction(func(tx *gorm.DB) error {
		inputPrice := input.InputPricePer1KCents
		if inputPrice <= 0 {
			inputPrice = 2
		}
		outputPrice := input.OutputPricePer1KCents
		if outputPrice <= 0 {
			outputPrice = 4
		}
		cacheHitPrice := input.CacheHitPriceCents
		if cacheHitPrice < 0 {
			cacheHitPrice = 0
		}
		if cacheHitPrice == 0 {
			cacheHitPrice = 1
		}
		minLivePrice := input.MinLivePriceCents
		if minLivePrice <= 0 {
			minLivePrice = 2
		}

		configs := []models.SystemConfig{
			{ConfigKey: "ai_base_url", ConfigValue: input.BaseURL},
			{ConfigKey: "ai_api_key", ConfigValue: input.APIKey},
			{ConfigKey: "ai_model_name", ConfigValue: input.ModelName},
			{ConfigKey: "ai_input_price_per_1k_cents", ConfigValue: strconv.Itoa(inputPrice)},
			{ConfigKey: "ai_output_price_per_1k_cents", ConfigValue: strconv.Itoa(outputPrice)},
			{ConfigKey: "ai_cache_hit_price_cents", ConfigValue: strconv.Itoa(cacheHitPrice)},
			{ConfigKey: "ai_min_live_price_cents", ConfigValue: strconv.Itoa(minLivePrice)},
		}

		for _, conf := range configs {
			var existing models.SystemConfig
			if err := tx.Where("config_key = ?", conf.ConfigKey).First(&existing).Error; err != nil {
				// 没找到则插入
				if err := tx.Create(&conf).Error; err != nil {
					return err
				}
			} else {
				// 找到则更新
				if err := tx.Model(&existing).Update("config_value", conf.ConfigValue).Error; err != nil {
					return err
				}
			}
		}
		return nil
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "配置已保存"})
}

type RechargeAiBalanceInput struct {
	AmountCents int    `json:"amount_cents" binding:"required"`
	Note        string `json:"note"`
}

func (h *SuperAdminHandler) RechargeAiBalance(c *gin.Context) {
	idStr := c.Param("id")
	userID, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})
		return
	}

	var input RechargeAiBalanceInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if input.AmountCents <= 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "充值金额必须大于 0"})
		return
	}

	var user models.User
	if err := h.db.First(&user, uint(userID)).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	newBalance := user.AiBalanceCents + input.AmountCents
	if err := h.db.Model(&user).Update("ai_balance_cents", newBalance).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "充值失败"})
		return
	}

	operatorID, _ := c.Get("user_id")
	operatorName := "Unknown Admin"
	if operatorID != nil {
		var admin models.User
		if err := h.db.First(&admin, operatorID.(uint)).Error; err == nil {
			operatorName = admin.Nickname
		}
		h.db.Create(&models.AdminLog{
			AdminID:   operatorID.(uint),
			AdminName: operatorName,
			Action:    "云考余额充值",
			Target:    user.Nickname,
			Detail:    fmt.Sprintf("金额 ¥%.2f，备注：%s", float64(input.AmountCents)/100.0, strings.TrimSpace(input.Note)),
		})
	}

	c.JSON(http.StatusOK, gin.H{
		"message":          "充值成功",
		"user_id":          user.ID,
		"student_id":       user.StudentID,
		"ai_balance_cents": newBalance,
		"ai_balance_yuan":  float64(newBalance) / 100.0,
		"recharged_cents":  input.AmountCents,
		"recharged_yuan":   float64(input.AmountCents) / 100.0,
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
