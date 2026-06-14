package handlers

import (
	"net/http"
	"strconv"
	"time"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// VipHandler VIP 权限处理器
type VipHandler struct {
	db *gorm.DB
}

// NewVipHandler 创建 VIP 处理器
func NewVipHandler(db *gorm.DB) *VipHandler {
	return &VipHandler{db: db}
}

// CheckVip 检查当前用户的 VIP 状态（桌面端调用）
func (h *VipHandler) CheckVip(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	isVip := false
	var expiryStr string
	if user.VipExpiry != nil && user.VipExpiry.After(time.Now()) {
		isVip = true
		expiryStr = user.VipExpiry.Format("2006-01-02 15:04:05")
	}

	c.JSON(http.StatusOK, gin.H{
		"is_vip":          isVip,
		"vip_expiry":      expiryStr,
		"student_id":      user.StudentID,
		"nickname":        user.Nickname,
		"ai_balance_cents": user.AiBalanceCents,
		"ai_balance_yuan":  float64(user.AiBalanceCents) / 100.0,
	})
}

// GrantVipInput 管理员为用户授予 VIP 的输入
type GrantVipInput struct {
	UserID uint `json:"user_id" binding:"required"`
	Days   int  `json:"days" binding:"required,min=1"`
}

// GrantVip 超级管理员为用户授予 VIP（控制台操作）
func (h *VipHandler) GrantVip(c *gin.Context) {
	var input GrantVipInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	var user models.User
	if err := h.db.First(&user, input.UserID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	// 如果用户当前 VIP 未过期，从当前到期时间续期；否则从现在开始计算
	now := time.Now()
	var newExpiry time.Time
	if user.VipExpiry != nil && user.VipExpiry.After(now) {
		newExpiry = user.VipExpiry.Add(time.Duration(input.Days) * 24 * time.Hour)
	} else {
		newExpiry = now.Add(time.Duration(input.Days) * 24 * time.Hour)
	}

	if err := h.db.Model(&user).Update("vip_expiry", newExpiry).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"message":    "VIP 授予成功",
		"user_id":    user.ID,
		"student_id": user.StudentID,
		"vip_expiry": newExpiry.Format("2006-01-02 15:04:05"),
	})
}

// RevokeVip 超级管理员撤销用户 VIP
func (h *VipHandler) RevokeVip(c *gin.Context) {
	idStr := c.Param("user_id")
	userID, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})
		return
	}

	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	if err := h.db.Model(&user).Update("vip_expiry", nil).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"message":    "VIP 已撤销",
		"user_id":    user.ID,
		"student_id": user.StudentID,
	})
}
