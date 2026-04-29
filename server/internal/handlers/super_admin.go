package handlers

import (
	"net/http"
	"strconv"

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

	defaultPassword := "password123"
	hashedPassword, _ := bcrypt.GenerateFromPassword([]byte(defaultPassword), bcrypt.DefaultCost)

	h.db.Model(&models.User{}).Where("id = ?", userID).Update("password_hash", string(hashedPassword))
	c.JSON(http.StatusOK, gin.H{"message": "密码已重置为: " + defaultPassword})
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

// GetAdminLogs 获取管理员操作日志
func (h *SuperAdminHandler) GetAdminLogs(c *gin.Context) {
	var logs []models.AdminActionLog
	h.db.Preload("Admin").Order("created_at DESC").Limit(100).Find(&logs)
	c.JSON(http.StatusOK, logs)
}