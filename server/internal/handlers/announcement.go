package handlers

import (
	"log"
	"net/http"
	"strconv"
	"time"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// AnnouncementHandler 公告处理器
type AnnouncementHandler struct {
	db *gorm.DB
}

// NewAnnouncementHandler 创建公告处理器
func NewAnnouncementHandler(db *gorm.DB) *AnnouncementHandler {
	return &AnnouncementHandler{db: db}
}

// priorityOrder 公告优先级排序片段：urgent > important > normal
const priorityOrder = "CASE WHEN priority = 'urgent' THEN 0 WHEN priority = 'important' THEN 1 ELSE 2 END, created_at DESC"

// visibleUnreadScope 返回对指定用户可见的未读公告基础查询（已发布 + 已到发布时间 + 未过期 + 用户可见范围）
func (h *AnnouncementHandler) visibleUnreadScope(db *gorm.DB, user models.User) *gorm.DB {
	now := time.Now()
	return db.
		Where("status = ?", "published").
		Where("(publish_at IS NULL OR publish_at <= ?)", now).
		Where("(expires_at IS NULL OR expires_at > ?)", now).
		Where("(created_at >= ? OR include_new_users = ?)", user.CreatedAt, true)
}

// GetList 获取公告列表（公开，公告中心）
// 保留已过期公告作为历史记录，但隐藏草稿、归档和未到发布时间的公告
func (h *AnnouncementHandler) GetList(c *gin.Context) {
	now := time.Now()
	var announcements []models.Announcement
	if err := h.db.
		Preload("Creator").
		Where("status = ?", "published").
		Where("(publish_at IS NULL OR publish_at <= ?)", now).
		Order("is_pinned DESC, " + priorityOrder).
		Limit(50).
		Find(&announcements).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取公告列表失败"})
		return
	}
	c.JSON(http.StatusOK, announcements)
}

// GetActive 获取置顶公告（用于首页展示）
func (h *AnnouncementHandler) GetActive(c *gin.Context) {
	now := time.Now()
	var announcements []models.Announcement
	if err := h.db.
		Preload("Creator").
		Where("is_pinned = ?", true).
		Where("status = ?", "published").
		Where("(publish_at IS NULL OR publish_at <= ?)", now).
		Order(priorityOrder).
		Limit(10).
		Find(&announcements).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取公告列表失败"})
		return
	}
	c.JSON(http.StatusOK, announcements)
}

// GetOne 获取公告详情
func (h *AnnouncementHandler) GetOne(c *gin.Context) {
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的公告ID"})
		return
	}

	var announcement models.Announcement
	if err := h.db.Preload("Creator").First(&announcement, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "公告不存在"})
		return
	}

	c.JSON(http.StatusOK, announcement)
}

// CreateAnnouncementInput 创建公告输入
type CreateAnnouncementInput struct {
	Title           string     `json:"title" binding:"required"`
	Content         string     `json:"content" binding:"required"`
	IsPinned        bool       `json:"is_pinned"`
	Status          string     `json:"status"`
	DisplayMode     string     `json:"display_mode"`
	Priority        string     `json:"priority"`
	PublishAt       *time.Time `json:"publish_at"`
	ExpiresAt       *time.Time `json:"expires_at"`
	IncludeNewUsers bool       `json:"include_new_users"`
}

// Create 创建公告（仅管理员）
func (h *AnnouncementHandler) Create(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var input CreateAnnouncementInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 设置默认值
	status := input.Status
	if status == "" {
		status = "published"
	}
	displayMode := input.DisplayMode
	if displayMode == "" {
		displayMode = "center"
	}
	priority := input.Priority
	if priority == "" {
		priority = "normal"
	}

	announcement := models.Announcement{
		Title:           input.Title,
		Content:         input.Content,
		IsPinned:        input.IsPinned,
		Status:          status,
		DisplayMode:     displayMode,
		Priority:        priority,
		PublishAt:       input.PublishAt,
		ExpiresAt:       input.ExpiresAt,
		IncludeNewUsers: input.IncludeNewUsers,
		CreatedBy:       userID.(uint),
	}

	if err := h.db.Create(&announcement).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建公告失败"})
		return
	}

	// 管理员创建公告，经验+1
	h.db.Model(&models.User{}).Where("id = ?", userID).UpdateColumn("admin_exp", gorm.Expr("COALESCE(admin_exp, 0) + 1"))

	if err := h.db.Preload("Creator").First(&announcement, announcement.ID).Error; err != nil {
		log.Printf("[DB_WARN] Failed to re-fetch announcement with creator after create: %v", err)
	}
	c.JSON(http.StatusCreated, announcement)
}

// UpdateAnnouncementInput 更新公告输入
type UpdateAnnouncementInput struct {
	Title           *string    `json:"title"`
	Content         *string    `json:"content"`
	IsPinned        *bool      `json:"is_pinned"`
	Status          *string    `json:"status"`
	DisplayMode     *string    `json:"display_mode"`
	Priority        *string    `json:"priority"`
	PublishAt       *time.Time `json:"publish_at"`
	ExpiresAt       *time.Time `json:"expires_at"`
	IncludeNewUsers *bool      `json:"include_new_users"`
}

// Update 更新公告（仅管理员）
func (h *AnnouncementHandler) Update(c *gin.Context) {
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的公告ID"})
		return
	}

	var announcement models.Announcement
	if err := h.db.First(&announcement, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "公告不存在"})
		return
	}

	var input UpdateAnnouncementInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	updates := make(map[string]interface{})
	if input.Title != nil {
		updates["title"] = *input.Title
	}
	if input.Content != nil {
		updates["content"] = *input.Content
	}
	if input.IsPinned != nil {
		updates["is_pinned"] = *input.IsPinned
	}
	if input.Status != nil {
		updates["status"] = *input.Status
	}
	if input.DisplayMode != nil {
		updates["display_mode"] = *input.DisplayMode
	}
	if input.Priority != nil {
		updates["priority"] = *input.Priority
	}
	if input.PublishAt != nil {
		updates["publish_at"] = *input.PublishAt
	}
	if input.ExpiresAt != nil {
		updates["expires_at"] = *input.ExpiresAt
	}
	if input.IncludeNewUsers != nil {
		updates["include_new_users"] = *input.IncludeNewUsers
	}

	if err := h.db.Model(&announcement).Updates(updates).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新公告失败"})
		return
	}
	if err := h.db.Preload("Creator").First(&announcement, id).Error; err != nil {
		log.Printf("[DB_WARN] Failed to re-fetch announcement with creator after update: %v", err)
	}
	c.JSON(http.StatusOK, announcement)
}

// Delete 删除公告（仅管理员）
func (h *AnnouncementHandler) Delete(c *gin.Context) {
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的公告ID"})
		return
	}

	if err := h.db.Delete(&models.Announcement{}, id).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除公告失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "删除成功"})
}

// GetUnread 获取当前用户未读公告（已发布 + 已到发布时间 + 未过期 + 用户可见）
func (h *AnnouncementHandler) GetUnread(c *gin.Context) {
	userID, exists := c.Get("user_id")
	uid, ok := userID.(uint)
	if !exists || !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "无效的用户身份"})
		return
	}

	var user models.User
	if err := h.db.Select("id", "created_at").First(&user, uid).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	var announcements []models.Announcement
	if err := h.visibleUnreadScope(h.db, user).
		Preload("Creator").
		Where("id NOT IN (SELECT announcement_id FROM announcement_reads WHERE user_id = ?)", uid).
		Order(priorityOrder).
		Limit(50).
		Find(&announcements).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取未读公告失败"})
		return
	}
	c.JSON(http.StatusOK, announcements)
}

// MarkRead 标记公告已读
func (h *AnnouncementHandler) MarkRead(c *gin.Context) {
	userID, exists := c.Get("user_id")
	uid, ok := userID.(uint)
	if !exists || !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "无效的用户身份"})
		return
	}

	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的公告ID"})
		return
	}

	if err := h.db.Where("user_id = ? AND announcement_id = ?", uid, id).
		FirstOrCreate(&models.AnnouncementRead{UserID: uid, AnnouncementID: uint(id), ReadAt: time.Now()}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "标记公告已读失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "ok"})
}

// GetUnreadCount 获取当前用户未读公告数量
func (h *AnnouncementHandler) GetUnreadCount(c *gin.Context) {
	userID, exists := c.Get("user_id")
	uid, ok := userID.(uint)
	if !exists || !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "无效的用户身份"})
		return
	}

	var user models.User
	if err := h.db.Select("id", "created_at").First(&user, uid).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	base := h.visibleUnreadScope(h.db, user).
		Where("id NOT IN (SELECT announcement_id FROM announcement_reads WHERE user_id = ?)", uid)

	var count int64
	base.Model(&models.Announcement{}).Count(&count)

	var urgentCount int64
	h.visibleUnreadScope(h.db, user).
		Where("id NOT IN (SELECT announcement_id FROM announcement_reads WHERE user_id = ?)", uid).
		Where("priority = ?", "urgent").
		Model(&models.Announcement{}).
		Count(&urgentCount)

	c.JSON(http.StatusOK, gin.H{
		"count":      count,
		"has_urgent": urgentCount > 0,
	})
}

// MarkAllReadInput 批量已读输入
type MarkAllReadInput struct {
	AnnouncementIDs []uint `json:"announcement_ids" binding:"required,max=100"`
}

// MarkAllRead 批量标记公告已读
func (h *AnnouncementHandler) MarkAllRead(c *gin.Context) {
	userID, exists := c.Get("user_id")
	uid, ok := userID.(uint)
	if !exists || !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "无效的用户身份"})
		return
	}

	var user models.User
	if err := h.db.Select("id", "created_at").First(&user, uid).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	var input MarkAllReadInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请提供有效的公告ID列表（最多100个）"})
		return
	}

	// 去重
	seen := map[uint]bool{}
	unique := make([]uint, 0, len(input.AnnouncementIDs))
	for _, aid := range input.AnnouncementIDs {
		if !seen[aid] {
			seen[aid] = true
			unique = append(unique, aid)
		}
	}

	now := time.Now()
	tx := h.db.Begin()
	for _, aid := range unique {
		// 仅对当前用户可见的公告标记已读
		var ann models.Announcement
		if err := h.visibleUnreadScope(tx, user).Where("id = ?", aid).First(&ann).Error; err != nil {
			continue // 跳过不可见或不存在的公告
		}
		tx.Where("user_id = ? AND announcement_id = ?", uid, aid).
			FirstOrCreate(&models.AnnouncementRead{UserID: uid, AnnouncementID: aid, ReadAt: now})
	}
	if err := tx.Commit().Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "标记已读失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "ok"})
}

// GetAdminList 管理员公告列表（含草稿、计划发布、已过期、已归档）
func (h *AnnouncementHandler) GetAdminList(c *gin.Context) {
	var announcements []models.Announcement
	if err := h.db.
		Preload("Creator").
		Order("is_pinned DESC, " + priorityOrder).
		Find(&announcements).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取公告列表失败"})
		return
	}
	c.JSON(http.StatusOK, announcements)
}
