package handlers

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"xiaoyuan/internal/models"
)

// UserHandler 用户处理器
type UserHandler struct {
	db *gorm.DB
}

// NewUserHandler 创建用户处理器
func NewUserHandler(db *gorm.DB) *UserHandler {
	return &UserHandler{db: db}
}

// GetProfile 获取个人资料
func (h *UserHandler) GetProfile(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	c.JSON(http.StatusOK, user)
}

// UpdateProfileInput 更新资料输入
type UpdateProfileInput struct {
	Nickname string `json:"nickname"`
}

// UpdateProfile 更新个人资料
func (h *UserHandler) UpdateProfile(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var input UpdateProfileInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	if input.Nickname == "" {
		var user models.User
		if err := h.db.First(&user, userID).Error; err != nil {
			c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
			return
		}
		c.JSON(http.StatusOK, user)
		return
	}

	h.db.Model(&models.User{}).Where("id = ?", userID).Update("nickname", input.Nickname)

	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	c.JSON(http.StatusOK, user)
}

// UpdateAvatarInput 更新头像输入
type UpdateAvatarInput struct {
	Avatar string `json:"avatar" binding:"required"`
}

// UpdateAvatar 更新头像
func (h *UserHandler) UpdateAvatar(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var input UpdateAvatarInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	h.db.Model(&models.User{}).Where("id = ?", userID).Update("avatar", input.Avatar)
	c.JSON(http.StatusOK, gin.H{"message": "头像更新成功"})
}

// UpdateBackgroundInput 更新背景图输入
type UpdateBackgroundInput struct {
	Background string `json:"background" binding:"required"`
}

// UpdateBackground 更新背景图
func (h *UserHandler) UpdateBackground(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var input UpdateBackgroundInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	h.db.Model(&models.User{}).Where("id = ?", userID).Update("background", input.Background)
	c.JSON(http.StatusOK, gin.H{"message": "背景图更新成功"})
}

// NightModeInput 夜间模式设置输入
type NightModeInput struct {
	NightMode bool `json:"night_mode"`
}

// UpdateNightMode 更新夜间模式设置
func (h *UserHandler) UpdateNightMode(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var input NightModeInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	h.db.Model(&models.User{}).Where("id = ?", userID).Update("night_mode", input.NightMode)
	c.JSON(http.StatusOK, gin.H{"message": "夜间模式设置成功"})
}

// GetUserInfo 获取任意用户信息
func (h *UserHandler) GetUserInfo(c *gin.Context) {
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})
		return
	}

	var user models.User
	if err := h.db.First(&user, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	c.JSON(http.StatusOK, user)
}