package handlers



import (

	"fmt"
	"net/http"
	"os"
	"strconv"

	"time"



	"github.com/gin-gonic/gin"

	"golang.org/x/crypto/bcrypt"

	"gorm.io/gorm"

	"shenliyuan/internal/models"

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

	query.Order("created_at DESC").Find(&users)



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



	h.db.Model(&user).Update("role", input.Role)

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



	h.db.Model(&models.User{}).Where("id = ?", userID).Update("credit_score", input.CreditScore)

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



	h.db.Delete(&user)

	c.JSON(http.StatusOK, gin.H{"message": "用户已删除"})

}



// Statistics 系统统计

type Statistics struct {

	TotalUsers      int64 `json:"total_users"`

	TotalPosts      int64 `json:"total_posts"`

	TotalReports    int64 `json:"total_reports"`

	PendingReports  int64 `json:"pending_reports"`

	TotalAppeals    int64 `json:"total_appeals"`

	PendingAppeals  int64 `json:"pending_appeals"`

	AdminCount      int64 `json:"admin_count"`

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

	ID        uint      `json:"id"`

	AdminID   uint      `json:"admin_id"`

	AdminName string    `json:"admin_name"`

	Action    string    `json:"action"`

	Target    string    `json:"target"`

	Detail    string    `json:"detail"`

	CreatedAt time.Time `json:"created_at"`

	AdminExp  int       `json:"admin_exp"`  // 当前管理员经验

	AdminRole string    `json:"admin_role"` // 管理员角色

}



// GetAdminLogs 获取管理员操作日志（含经验信息）

func (h *SuperAdminHandler) GetAdminLogs(c *gin.Context) {

	var logs []models.AdminLog

	h.db.Preload("Admin").Order("created_at DESC").Limit(200).Find(&logs)



	result := make([]AdminLogItem, len(logs))

	for i, log := range logs {

		result[i] = AdminLogItem{

			ID:        log.ID,

			AdminID:   log.AdminID,

			AdminName: log.AdminName,

			Action:    log.Action,

			Target:    log.Target,

			Detail:    log.Detail,

			CreatedAt: log.CreatedAt,

			AdminExp:  log.Admin.AdminExp,

			AdminRole: string(log.Admin.Role),

		}

	}



	c.JSON(http.StatusOK, result)

}



// RevokeAdminExpInput 追回管理员经验输入

type RevokeAdminExpInput struct {

	AdminID uint `json:"admin_id" binding:"required"`

	Amount  int  `json:"amount" binding:"required,min=1"`

	Reason  string `json:"reason"`

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

		h.db.Select("role").First(&operator, operatorID)

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

	h.db.Model(&target).Update("admin_exp", newExp)



	// 记录操作日志

	reason := input.Reason

	if reason == "" {

		reason = "追回经验"

	}

	var operator models.User

	h.db.Select("nickname").First(&operator, operatorID)

	h.db.Create(&models.AdminLog{

		AdminID: operatorID.(uint),

		AdminName: operator.Nickname,

		Action: "追回管理员经验",

		Target: target.Nickname,

		Detail: fmt.Sprintf("追回 %d 经验（原因: %s），剩余 %d", input.Amount, reason, newExp),

	})



	c.JSON(http.StatusOK, gin.H{

		"message":      "经验已追回",

		"admin_id":     input.AdminID,

		"revoked":      input.Amount,

		"remaining":    newExp,

	})

}



// AiConfigInput AI 全局配置输入
type AiConfigInput struct {
	BaseURL   string `json:"base_url" binding:"required"`
	APIKey    string `json:"api_key" binding:"required"`
	ModelName string `json:"model_name" binding:"required"`
}

// GetAiConfig 获取全局 AI 配置
func (h *SuperAdminHandler) GetAiConfig(c *gin.Context) {
	configKeys := []string{"ai_base_url", "ai_api_key", "ai_model_name"}
	var configs []models.SystemConfig
	h.db.Where("config_key IN ?", configKeys).Find(&configs)

	configMap := make(map[string]string)
	for _, conf := range configs {
		configMap[conf.ConfigKey] = conf.ConfigValue
	}

	c.JSON(http.StatusOK, gin.H{
		"base_url":   configMap["ai_base_url"],
		"api_key":    configMap["ai_api_key"],
		"model_name": configMap["ai_model_name"],
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
		configs := []models.SystemConfig{
			{ConfigKey: "ai_base_url", ConfigValue: input.BaseURL},
			{ConfigKey: "ai_api_key", ConfigValue: input.APIKey},
			{ConfigKey: "ai_model_name", ConfigValue: input.ModelName},
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

// GetLotteryParticipants 获取当前抽奖的参与者
func (h *SuperAdminHandler) GetLotteryParticipants(c *gin.Context) {
	var event models.LotteryEvent
	err := h.db.Order("status ASC, created_at DESC").First(&event).Error
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "暂无抽奖活动"})
		return
	}

	var participants []models.LotteryParticipant
	h.db.Where("lottery_id = ?", event.ID).Preload("User").Find(&participants)
	
	c.JSON(http.StatusOK, gin.H{
		"event": event,
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
