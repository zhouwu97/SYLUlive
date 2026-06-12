package handlers

import (
	"net/http"
	"strconv"
	"time"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
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

	// 动态计算今天是否已经签到（统一 Asia/Shanghai 时区）
	loc, _ := time.LoadLocation("Asia/Shanghai")
	todayStr := time.Now().In(loc).Format("2006-01-02")
	if user.LastCheckInDate == todayStr {
		user.IsCheckedInToday = true
	} else {
		user.IsCheckedInToday = false
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
		c.JSON(http.StatusBadRequest, gin.H{"error": "昵称不能为空"})
		return
	}

	if err := h.db.Model(&models.User{}).Where("id = ?", userID).Update("nickname", input.Nickname).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

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

	if err := h.db.Model(&models.User{}).Where("id = ?", userID).Update("avatar", input.Avatar).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
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

	if err := h.db.Model(&models.User{}).Where("id = ?", userID).Update("background", input.Background).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
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

	if err := h.db.Model(&models.User{}).Where("id = ?", userID).Update("night_mode", input.NightMode).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "夜间模式设置成功"})
}

// GetUserInfo 获取任意用户信息
func (h *UserHandler) GetUserInfo(c *gin.Context) {
	currentUserID, exists := c.Get("user_id")
	
	idStr := c.Param("id")
	targetID, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})
		return
	}

	var user models.User
	if err := h.db.First(&user, targetID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	isFollowing := false
	if exists {
		var count int64
		// 使用 EXISTS 子查询优化
		h.db.Raw("SELECT EXISTS(SELECT 1 FROM user_follows WHERE follower_id = ? AND following_id = ?)", currentUserID, targetID).Scan(&count)
		isFollowing = count > 0
	}
	user.IsFollowing = isFollowing

	c.JSON(http.StatusOK, user)
}

// GetFollowing 获取关注列表
func (h *UserHandler) GetFollowing(c *gin.Context) {
	targetIDStr := c.Param("id")
	targetID, err := strconv.ParseUint(targetIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})
		return
	}

	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "20"))
	offset := (page - 1) * limit

	var follows []models.UserFollow
	var total int64
	h.db.Model(&models.UserFollow{}).Where("follower_id = ?", targetID).Count(&total)
	h.db.Where("follower_id = ?", targetID).Order("created_at DESC").Offset(offset).Limit(limit).Find(&follows)

	var userIDs []uint
	for _, f := range follows {
		userIDs = append(userIDs, f.FollowingID)
	}

	users := make([]models.User, 0)
	if len(userIDs) > 0 {
		h.db.Where("id IN ?", userIDs).Find(&users)
	}

	c.JSON(http.StatusOK, gin.H{
		"items": users,
		"total": total,
		"page":  page,
		"limit": limit,
	})
}

// GetFollowers 获取粉丝列表
func (h *UserHandler) GetFollowers(c *gin.Context) {
	targetIDStr := c.Param("id")
	targetID, err := strconv.ParseUint(targetIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})
		return
	}

	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "20"))
	offset := (page - 1) * limit

	var follows []models.UserFollow
	var total int64
	h.db.Model(&models.UserFollow{}).Where("following_id = ?", targetID).Count(&total)
	h.db.Where("following_id = ?", targetID).Order("created_at DESC").Offset(offset).Limit(limit).Find(&follows)

	var userIDs []uint
	for _, f := range follows {
		userIDs = append(userIDs, f.FollowerID)
	}

	users := make([]models.User, 0)
	if len(userIDs) > 0 {
		h.db.Where("id IN ?", userIDs).Find(&users)
	}

	c.JSON(http.StatusOK, gin.H{
		"items": users,
		"total": total,
		"page":  page,
		"limit": limit,
	})
}

// Follow 关注用户
func (h *UserHandler) Follow(c *gin.Context) {
	followerIDAny, _ := c.Get("user_id")
	followerID := followerIDAny.(uint)

	followingIDStr := c.Param("id")
	followingID, err := strconv.ParseUint(followingIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的目标用户ID"})
		return
	}

	if followerID == uint(followingID) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不能关注自己"})
		return
	}

	var targetUser models.User
	if err := h.db.First(&targetUser, followingID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "目标用户不存在"})
		return
	}

	err = h.db.Transaction(func(tx *gorm.DB) error {
		var follow models.UserFollow
		result := tx.Where("follower_id = ? AND following_id = ?", followerID, followingID).FirstOrCreate(&follow, models.UserFollow{
			FollowerID:  followerID,
			FollowingID: uint(followingID),
		})
		
		if result.RowsAffected > 0 {
			tx.Model(&models.User{}).Where("id = ?", followerID).UpdateColumn("following_count", gorm.Expr("following_count + 1"))
			tx.Model(&models.User{}).Where("id = ?", followingID).UpdateColumn("followers_count", gorm.Expr("followers_count + 1"))
		}
		return nil
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "关注失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "关注成功", "following": true})
}

// Unfollow 取消关注用户
func (h *UserHandler) Unfollow(c *gin.Context) {
	followerIDAny, _ := c.Get("user_id")
	followerID := followerIDAny.(uint)

	followingIDStr := c.Param("id")
	followingID, err := strconv.ParseUint(followingIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的目标用户ID"})
		return
	}

	err = h.db.Transaction(func(tx *gorm.DB) error {
		result := tx.Where("follower_id = ? AND following_id = ?", followerID, followingID).Delete(&models.UserFollow{})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected > 0 {
			tx.Model(&models.User{}).Where("id = ?", followerID).UpdateColumn("following_count", gorm.Expr("GREATEST(following_count - 1, 0)"))
			tx.Model(&models.User{}).Where("id = ?", followingID).UpdateColumn("followers_count", gorm.Expr("GREATEST(followers_count - 1, 0)"))
		}
		return nil
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "取消关注失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "取消关注成功", "following": false})
}

// IsFollowing 检查当前用户是否关注了目标用户
func (h *UserHandler) IsFollowing(c *gin.Context) {
	followerIDAny, _ := c.Get("user_id")
	followerID := followerIDAny.(uint)

	followingIDStr := c.Param("id")
	followingID, err := strconv.ParseUint(followingIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的目标用户ID"})
		return
	}

	var count int64
	h.db.Model(&models.UserFollow{}).Where("follower_id = ? AND following_id = ?", followerID, followingID).Count(&count)

	c.JSON(http.StatusOK, gin.H{"following": count > 0})
}

// GetUserPosts 获取用户发布的帖子
func (h *UserHandler) GetUserPosts(c *gin.Context) {
	targetIDStr := c.Param("id")
	targetID, err := strconv.ParseUint(targetIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})
		return
	}

	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "20"))
	offset := (page - 1) * limit

	var posts []models.Post
	if err := h.db.Preload("Author").Where("author_id = ? AND status = ?", targetID, "normal").Order("created_at DESC").Offset(offset).Limit(limit).Find(&posts).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取帖子失败"})
		return
	}

	c.JSON(http.StatusOK, posts)
}

// UpdateDeviceTokenInput 更新设备Token输入
type UpdateDeviceTokenInput struct {
	DeviceToken string `json:"device_token" binding:"required"`
}

// UpdateDeviceToken 更新极光设备Token（用户登录时前端调用）
func (h *UserHandler) UpdateDeviceToken(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var input UpdateDeviceTokenInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	if err := h.db.Model(&models.User{}).Where("id = ?", userID).Update("device_token", input.DeviceToken).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "设备Token更新成功"})
}
