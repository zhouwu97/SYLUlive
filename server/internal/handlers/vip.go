package handlers

import (
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// VipHandler VIP 权限处理器
type VipHandler struct {
	db                *gorm.DB
	jpushAppKey       string
	jpushMasterSecret string
}

// NewVipHandler 创建 VIP 处理器
func NewVipHandler(db *gorm.DB, jpushAppKey, jpushMasterSecret string) *VipHandler {
	return &VipHandler{
		db:                db,
		jpushAppKey:       jpushAppKey,
		jpushMasterSecret: jpushMasterSecret,
	}
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
		"is_vip":           isVip,
		"vip_expiry":       expiryStr,
		"student_id":       user.StudentID,
		"nickname":         user.Nickname,
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

// PushVipUpdateInput 管理员向当前有效 VIP 用户推送版本更新通知
type PushVipUpdateInput struct {
	Title       string `json:"title"`
	Message     string `json:"message"`
	Version     string `json:"version"`
	DownloadURL string `json:"download_url" binding:"required"`
	DryRun      bool   `json:"dry_run"`
}

// PushUpdateToVip 向当前有效 VIP 用户推送 APP 更新通知（超级管理员）
func (h *VipHandler) PushUpdateToVip(c *gin.Context) {
	var input PushVipUpdateInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	input.Title = strings.TrimSpace(input.Title)
	input.Message = strings.TrimSpace(input.Message)
	input.Version = strings.TrimSpace(input.Version)
	input.DownloadURL = strings.TrimSpace(input.DownloadURL)

	parsedURL, err := url.ParseRequestURI(input.DownloadURL)
	if err != nil || parsedURL.Scheme == "" || parsedURL.Host == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "download_url 必须是完整的 http/https 链接"})
		return
	}
	if parsedURL.Scheme != "http" && parsedURL.Scheme != "https" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "download_url 仅支持 http/https"})
		return
	}

	if input.Title == "" {
		input.Title = "发现新版本"
	}
	if input.Message == "" {
		if input.Version != "" {
			input.Message = "高级用户可更新到 " + input.Version
		} else {
			input.Message = "高级用户可下载最新版本"
		}
	}

	var users []models.User
	now := time.Now()
	if err := h.db.
		Where("vip_expiry IS NOT NULL AND vip_expiry > ? AND device_token <> ''", now).
		Select("id, student_id, nickname, device_token, vip_expiry").
		Find(&users).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询 VIP 用户失败"})
		return
	}

	if input.DryRun {
		c.JSON(http.StatusOK, gin.H{
			"message":      "更新推送预演完成",
			"dry_run":      true,
			"target_count": len(users),
			"sent":         0,
			"failed":       0,
		})
		return
	}

	if h.jpushAppKey == "" || h.jpushMasterSecret == "" {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "JPush 配置未设置，无法推送"})
		return
	}

	jpush := utils.NewJPushClient(h.jpushAppKey, h.jpushMasterSecret)
	extras := map[string]interface{}{
		"type":         "app_update",
		"download_url": input.DownloadURL,
	}
	if input.Version != "" {
		extras["version"] = input.Version
	}

	failedUsers := make([]gin.H, 0)
	sent := 0
	for _, user := range users {
		if err := jpush.SendNotification(user.DeviceToken, input.Title, input.Message, extras); err != nil {
			failedUsers = append(failedUsers, gin.H{
				"user_id":    user.ID,
				"student_id": user.StudentID,
				"error":      err.Error(),
			})
			continue
		}
		sent++
	}

	c.JSON(http.StatusOK, gin.H{
		"message":      "更新推送完成",
		"dry_run":      false,
		"target_count": len(users),
		"sent":         sent,
		"failed":       len(failedUsers),
		"failed_users": failedUsers,
	})
}
