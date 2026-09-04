package handlers

import (
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// UserHandler 用户处理器
type UserHandler struct {
	db *gorm.DB
}

var schoolPersonalDataVisible atomic.Bool

func init() {
	schoolPersonalDataVisible.Store(true)
}

// SetSchoolPersonalDataVisible 控制会话和本人资料是否包含历史学校个人字段。
// 生产退役开关打开后由启动入口关闭，测试和分阶段迁移默认保持兼容。
func SetSchoolPersonalDataVisible(visible bool) {
	schoolPersonalDataVisible.Store(visible)
}

// PublicUserResponse 是公开资料接口的最小响应模型。
type PublicUserResponse = models.PublicUserResponse

func publicUserResponse(user models.User) PublicUserResponse {
	return models.PublicUser(user)
}

// SelfUserResponse 仅用于当前登录用户；学校个人字段由退役开关控制，默认只保留兼容形状。
type SelfUserResponse struct {
	ID                    uint        `json:"id"`
	StudentID             string      `json:"student_id,omitempty"`
	StudentVerified       bool        `json:"student_verified,omitempty"`
	EmailMasked           string      `json:"email_masked"`
	EmailBound            bool        `json:"email_bound"`
	LoginMethods          []string    `json:"login_methods"`
	CanResetViaEmail      bool        `json:"can_reset_via_email"`
	CanResetViaEdu        bool        `json:"can_reset_via_edu,omitempty"`
	Nickname              string      `json:"nickname"`
	Gender                string      `json:"gender"`
	Avatar                string      `json:"avatar"`
	Background            string      `json:"background"`
	NightMode             bool        `json:"night_mode"`
	CreditScore           int         `json:"credit_score"`
	Role                  models.Role `json:"role"`
	AdminExp              int         `json:"admin_exp"`
	Exp                   int         `json:"exp"`
	ReportCount           int         `json:"report_count"`
	CreatedAt             time.Time   `json:"created_at"`
	EduStudentID          string      `json:"edu_student_id,omitempty"`
	EduBound              bool        `json:"edu_bound,omitempty"`
	EduAuthorized         bool        `json:"edu_authorized,omitempty"`
	EduSessionState       string      `json:"edu_session_state,omitempty"`
	EduGrade              string      `json:"edu_grade,omitempty"`
	EduCollege            string      `json:"edu_college,omitempty"`
	EduMajor              string      `json:"edu_major,omitempty"`
	IsCheckedInToday      bool        `json:"is_checked_in_today"`
	FollowersCount        int         `json:"followers_count"`
	FollowingCount        int         `json:"following_count"`
	TotalLikesReceived    int         `json:"total_likes_received"`
	IsFollowing           bool        `json:"is_following"`
	LegalConsentsActive   bool        `json:"legal_consents_active"`
	LegalConsentsRequired bool        `json:"legal_consents_required"`
	PushEnabled           bool        `json:"push_enabled"`
}

func selfUserResponse(user models.User, consentState models.LegalConsentState) SelfUserResponse {
	loginMethods := make([]string, 0, 2)
	if user.IsStudentVerified() && user.StudentID != "" {
		loginMethods = append(loginMethods, "student_id")
	}
	if user.EmailVerifiedAt != nil && user.Email != "" {
		loginMethods = append(loginMethods, "email")
	}
	response := SelfUserResponse{
		ID: user.ID, StudentID: user.StudentID, StudentVerified: user.IsStudentVerified(),
		EmailMasked: maskEmail(user.Email), EmailBound: user.EmailVerifiedAt != nil && user.Email != "",
		LoginMethods: loginMethods, CanResetViaEmail: user.EmailVerifiedAt != nil && user.Email != "",
		CanResetViaEdu: user.IsStudentVerified() && user.StudentID != "", Nickname: user.Nickname, Gender: user.Gender,
		Avatar: user.Avatar, Background: user.Background, NightMode: user.NightMode,
		CreditScore: user.CreditScore, Role: user.Role, AdminExp: user.AdminExp, Exp: user.Exp,
		ReportCount: user.ReportCount, CreatedAt: user.CreatedAt, EduStudentID: user.EduStudentID,
		EduBound: user.IsEduAuthorized(), EduAuthorized: user.IsEduAuthorized(), EduSessionState: user.EduSessionState,
		EduGrade: user.EduGrade, EduCollege: user.EduCollege,
		EduMajor: user.EduMajor, IsCheckedInToday: user.IsCheckedInToday,
		FollowersCount: user.FollowersCount, FollowingCount: user.FollowingCount,
		TotalLikesReceived: user.TotalLikesReceived, IsFollowing: user.IsFollowing,
		LegalConsentsActive:   consentState == models.LegalConsentStateActive,
		LegalConsentsRequired: consentState == models.LegalConsentStateRequired,
		PushEnabled:           user.PushDataProcessingEnabled,
	}
	if !schoolPersonalDataVisible.Load() {
		response.StudentID = ""
		response.StudentVerified = false
		response.CanResetViaEdu = false
		response.EduStudentID = ""
		response.EduBound = false
		response.EduAuthorized = false
		response.EduSessionState = ""
		response.EduGrade = ""
		response.EduCollege = ""
		response.EduMajor = ""
		response.LoginMethods = filterNonSchoolLoginMethods(response.LoginMethods)
	}
	return response
}

func filterNonSchoolLoginMethods(methods []string) []string {
	filtered := make([]string, 0, len(methods))
	for _, method := range methods {
		if method != "student_id" {
			filtered = append(filtered, method)
		}
	}
	return filtered
}

func selfUserResponseForDB(db *gorm.DB, user models.User) (SelfUserResponse, error) {
	consentState, err := models.LegalConsentStateForUser(db, user)
	if err != nil {
		return SelfUserResponse{}, err
	}
	return selfUserResponse(user, consentState), nil
}

func (h *UserHandler) selfUserResponse(user models.User) (SelfUserResponse, error) {
	return selfUserResponseForDB(h.db, user)
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

	// 是否已签到以当天事实记录为准，users.last_check_in_date 仅保留给旧接口兼容。
	loc, _ := time.LoadLocation("Asia/Shanghai")
	now := time.Now().In(loc)
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	var checkInCount int64
	if err := h.db.Model(&models.CheckIn{}).Where("user_id = ? AND check_in_date = ?", user.ID, today).Count(&checkInCount).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取签到状态失败"})
		return
	}
	user.IsCheckedInToday = checkInCount > 0

	response, err := h.selfUserResponse(user)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取授权状态失败"})
		return
	}
	c.JSON(http.StatusOK, response)
}

// UpdateProfileInput 更新资料输入
type UpdateProfileInput struct {
	Nickname string  `json:"nickname"`
	Gender   *string `json:"gender"`
}

// UpdateProfile 更新个人资料
func (h *UserHandler) UpdateProfile(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var input UpdateProfileInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	nickname := strings.TrimSpace(input.Nickname)
	if nickname == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "昵称不能为空"})
		return
	}

	if utf8.RuneCountInString(nickname) > 20 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "昵称不能超过20个字符"})
		return
	}

	updates := map[string]interface{}{
		"nickname": nickname,
	}

	if input.Gender != nil {
		gender := strings.TrimSpace(*input.Gender)

		if gender != "" && gender != "male" && gender != "female" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效的性别值"})
			return
		}

		updates["gender"] = gender
	}

	if err := h.db.Model(&models.User{}).Where("id = ?", userID).Updates(updates).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	response, err := h.selfUserResponse(user)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取授权状态失败"})
		return
	}
	c.JSON(http.StatusOK, response)
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

	avatar := versionedAvatarURL(input.Avatar)
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Update("avatar", avatar).Error; err != nil {
			return err
		}
		return services.ClaimPublicImagePathsForUser(tx, userID.(uint), avatar)
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "头像更新成功"})
}

func versionedAvatarURL(avatar string) string {
	parsed, err := url.Parse(avatar)
	if err != nil {
		return avatar
	}

	query := parsed.Query()
	query.Set("v", strconv.FormatInt(time.Now().UnixNano(), 10))
	parsed.RawQuery = query.Encode()
	return parsed.String()
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

	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Update("background", input.Background).Error; err != nil {
			return err
		}
		return services.ClaimPublicImagePathsForUser(tx, userID.(uint), input.Background)
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取用户资料失败"})
		return
	}

	response, err := h.selfUserResponse(user)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取授权状态失败"})
		return
	}
	c.JSON(http.StatusOK, response)
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
		h.db.Model(&models.UserFollow{}).Where("follower_id = ? AND following_id = ?", currentUserID, targetID).Count(&count)
		isFollowing = count > 0
	}
	user.IsFollowing = isFollowing

	c.JSON(http.StatusOK, publicUserResponse(user))
}

// GetFollowing 获取关注列表
func (h *UserHandler) GetFollowing(c *gin.Context) {
	targetIDStr := c.Param("id")
	targetID, err := strconv.ParseUint(targetIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})
		return
	}

	page, limit, offset := ParsePagination(c, 20, 50)

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
		users = orderUsersByIDs(users, userIDs)

		// 填充 IsFollowing
		currentUserIDAny, exists := c.Get("user_id")
		if exists {
			currentUserID := currentUserIDAny.(uint)
			var followingIDs []uint
			h.db.Model(&models.UserFollow{}).Where("follower_id = ? AND following_id IN ?", currentUserID, userIDs).Pluck("following_id", &followingIDs)

			followingMap := make(map[uint]bool)
			for _, id := range followingIDs {
				followingMap[id] = true
			}

			for i := range users {
				users[i].IsFollowing = followingMap[users[i].ID]
			}
		}
	}

	items := make([]PublicUserResponse, 0, len(users))
	for _, user := range users {
		items = append(items, publicUserResponse(user))
	}
	c.JSON(http.StatusOK, gin.H{
		"items": items,
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

	page, limit, offset := ParsePagination(c, 20, 50)

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
		users = orderUsersByIDs(users, userIDs)

		// 填充 IsFollowing
		currentUserIDAny, exists := c.Get("user_id")
		if exists {
			currentUserID := currentUserIDAny.(uint)
			var followingIDs []uint
			h.db.Model(&models.UserFollow{}).Where("follower_id = ? AND following_id IN ?", currentUserID, userIDs).Pluck("following_id", &followingIDs)

			followingMap := make(map[uint]bool)
			for _, id := range followingIDs {
				followingMap[id] = true
			}

			for i := range users {
				users[i].IsFollowing = followingMap[users[i].ID]
			}
		}
	}

	items := make([]PublicUserResponse, 0, len(users))
	for _, user := range users {
		items = append(items, publicUserResponse(user))
	}
	c.JSON(http.StatusOK, gin.H{
		"items": items,
		"total": total,
		"page":  page,
		"limit": limit,
	})
}

func orderUsersByIDs(users []models.User, ids []uint) []models.User {
	byID := make(map[uint]models.User, len(users))
	for _, user := range users {
		byID[user.ID] = user
	}
	ordered := make([]models.User, 0, len(users))
	for _, id := range ids {
		if user, exists := byID[id]; exists {
			ordered = append(ordered, user)
		}
	}
	return ordered
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

		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected > 0 {
			if err := tx.Model(&models.User{}).Where("id = ?", followerID).UpdateColumn("following_count", gorm.Expr("following_count + 1")).Error; err != nil {
				return err
			}
			if err := tx.Model(&models.User{}).Where("id = ?", followingID).UpdateColumn("followers_count", gorm.Expr("followers_count + 1")).Error; err != nil {
				return err
			}
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
			if err := tx.Model(&models.User{}).Where("id = ?", followerID).UpdateColumn("following_count", gorm.Expr("GREATEST(following_count - 1, 0)")).Error; err != nil {
				return err
			}
			if err := tx.Model(&models.User{}).Where("id = ?", followingID).UpdateColumn("followers_count", gorm.Expr("GREATEST(followers_count - 1, 0)")).Error; err != nil {
				return err
			}
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

	_, limit, offset := ParsePagination(c, 20, 50)

	var posts []models.Post
	if err := h.db.
		Preload("Author").
		Preload("Images").
		Preload("Images.File").
		Scopes(withPostImageVariants).
		Where("author_id = ? AND status = ? AND board_id != ?", targetID, models.PostStatusNormal, models.BoardMarket).
		Order("created_at DESC").
		Offset(offset).
		Limit(limit).
		Find(&posts).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取帖子失败"})
		return
	}
	_ = services.LoadTopicsForPosts(h.db, posts)

	c.JSON(http.StatusOK, posts)
}

// GetUserMarketPosts 获取用户主页展示的集市出售记录，包含已售出历史。
func (h *UserHandler) GetUserMarketPosts(c *gin.Context) {
	targetIDStr := c.Param("id")
	targetID, err := strconv.ParseUint(targetIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})
		return
	}

	page, limit, offset := ParsePagination(c, 20, 50)
	postType := c.DefaultQuery("post_type", "sell")

	buildQuery := func() *gorm.DB {
		return h.db.Model(&models.Post{}).Where(
			"author_id = ? AND board_id = ? AND post_type = ? AND status <> ?",
			targetID,
			models.BoardMarket,
			postType,
			models.PostStatusDeleted,
		)
	}

	var total int64
	if err := buildQuery().Count(&total).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取商品数量失败"})
		return
	}

	var sold int64
	if err := buildQuery().
		Where("status = ?", models.PostStatusSold).
		Count(&sold).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取售出数量失败"})
		return
	}

	var posts []models.Post
	if err := buildQuery().
		Preload("Author").
		Preload("Images").
		Preload("Images.File").
		Scopes(withPostImageVariants).
		Order("created_at DESC").
		Offset(offset).
		Limit(limit).
		Find(&posts).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取商品失败"})
		return
	}
	if posts == nil {
		posts = []models.Post{}
	}
	_ = services.LoadTopicsForPosts(h.db, posts)

	c.JSON(http.StatusOK, gin.H{
		"items": posts,
		"total": total,
		"sold":  sold,
		"page":  page,
		"limit": limit,
	})
}

// GetUserPostCount returns the number of visible posts created by a user.
func (h *UserHandler) GetUserPostCount(c *gin.Context) {
	targetID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})
		return
	}

	var count int64
	if err := h.db.Model(&models.Post{}).
		Where("author_id = ? AND status = ?", targetID, models.PostStatusNormal).
		Count(&count).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取内容数量失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"count": count})
}

// UpdateDeviceTokenInput 更新设备Token输入
type UpdateDeviceTokenInput struct {
	DeviceToken string `json:"device_token"`
}

type UpdatePushSettingsInput struct {
	Enabled        bool   `json:"enabled"`
	InstallationID string `json:"installation_id"`
	RegistrationID string `json:"registration_id"`
	NoticeVersion  string `json:"notice_version"`
	Platform       string `json:"platform"`
}

// UpdateDeviceToken 更新极光设备Token（用户登录时前端调用）
func (h *UserHandler) UpdateDeviceToken(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var input UpdateDeviceTokenInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if strings.TrimSpace(input.DeviceToken) != "" {
		c.JSON(http.StatusConflict, gin.H{
			"error": "请使用推送设置接口主动开启远程推送",
			"code":  "push_settings_required",
		})
		return
	}

	if err := h.db.Transaction(func(tx *gorm.DB) error {
		// 同一 RegistrationID 只能归属一个账号，切换账号时先解除旧绑定。
		if input.DeviceToken != "" {
			if err := tx.Model(&models.User{}).Where("device_token = ? AND id <> ?", input.DeviceToken, userID).Update("device_token", "").Error; err != nil {
				return err
			}
		}
		return tx.Model(&models.User{}).Where("id = ?", userID).Update("device_token", input.DeviceToken).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "设备Token更新成功"})
}

// UpdatePushSettings 原子更新单个安装实例的推送状态，不影响同一用户的其他设备。
func (h *UserHandler) UpdatePushSettings(c *gin.Context) {
	userID := c.GetUint("user_id")
	var input UpdatePushSettingsInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效"})
		return
	}

	input.InstallationID = strings.TrimSpace(input.InstallationID)
	input.RegistrationID = strings.TrimSpace(input.RegistrationID)
	input.NoticeVersion = strings.TrimSpace(input.NoticeVersion)
	input.Platform = strings.ToLower(strings.TrimSpace(input.Platform))
	if input.Platform == "" {
		input.Platform = "android"
	}
	if input.Platform != "android" && input.Platform != "ios" && input.Platform != "ohos" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "platform 无效"})
		return
	}
	if input.InstallationID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "installation_id 不能为空"})
		return
	}
	if input.Enabled && (input.RegistrationID == "" || input.NoticeVersion == "") {
		c.JSON(http.StatusBadRequest, gin.H{"error": "开启推送时 registration_id 和 notice_version 不能为空"})
		return
	}

	ignored := false
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, userID).Error; err != nil {
			return err
		}
		if input.Enabled && user.LegalConsentRevokedAt != nil {
			return gorm.ErrInvalidData
		}

		if input.Enabled {
			if err := tx.Model(&models.PushDevice{}).
				Where("registration_id = ? AND device_id <> ?", input.RegistrationID, input.InstallationID).
				Update("enabled", false).Error; err != nil {
				return err
			}
			var device models.PushDevice
			findErr := tx.Where("device_id = ?", input.InstallationID).First(&device).Error
			if findErr != nil && findErr != gorm.ErrRecordNotFound {
				return findErr
			}
			now := time.Now()
			if findErr == gorm.ErrRecordNotFound {
				device = models.PushDevice{
					UserID: userID, DeviceID: input.InstallationID,
					Platform: input.Platform, PushProvider: "jpush",
					RegistrationID: input.RegistrationID, Enabled: true,
					LastSeenAt: now,
				}
				if err := tx.Create(&device).Error; err != nil {
					return err
				}
			} else if err := tx.Model(&models.PushDevice{}).Where("id = ?", device.ID).Updates(map[string]interface{}{
				"user_id": userID, "platform": input.Platform, "push_provider": "jpush",
				"registration_id": input.RegistrationID, "enabled": true, "last_seen_at": now,
			}).Error; err != nil {
				return err
			}
			if device.UserID != userID {
				// 同一安装切换账号时，除了转移 PushDevice，还要清理旧版
				// User 聚合字段，避免通知查询 fallback 到旧账号 RID。
				if err := tx.Model(&models.User{}).
					Where("id = ? AND push_installation_id = ?", device.UserID, input.InstallationID).
					Updates(map[string]interface{}{
						"push_data_processing_enabled": false,
						"push_installation_id":         "",
						"push_notice_version":          "",
						"push_enabled_at":              nil,
						"device_token":                 "",
					}).Error; err != nil {
					return err
				}
			}
			return tx.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
				"push_data_processing_enabled": true,
				"push_installation_id":         input.InstallationID,
				"push_notice_version":          input.NoticeVersion,
				"push_enabled_at":              &now,
				"device_token":                 input.RegistrationID,
			}).Error
		}

		// 新模型按 installation_id 独立关闭，不能因为旧版 User 聚合字段
		// 当前指向另一台设备，就跳过这条 PushDevice 记录。
		if err := tx.Model(&models.PushDevice{}).Where("user_id = ? AND device_id = ?", userID, input.InstallationID).
			Updates(map[string]interface{}{"enabled": false, "last_seen_at": time.Now()}).Error; err != nil {
			return err
		}
		if user.PushInstallationID != "" && user.PushInstallationID != input.InstallationID {
			ignored = true
			return nil
		}
		return tx.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
			"push_data_processing_enabled": false,
			"push_installation_id":         "",
			"push_notice_version":          "",
			"push_enabled_at":              nil,
			"device_token":                 "",
		}).Error
	}); err != nil {
		if err == gorm.ErrInvalidData {
			c.JSON(http.StatusForbidden, gin.H{"error": "授权已撤销，请重新确认基础协议后再开启推送", "code": "legal_consent_required"})
			return
		}
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新推送设置失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"message": "推送设置已更新",
		"enabled": input.Enabled && !ignored,
		"ignored": ignored,
	})
}
