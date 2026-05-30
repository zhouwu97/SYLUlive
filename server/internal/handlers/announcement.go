package handlers

import (
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// AnnouncementHandler 公告处理器
type AnnouncementHandler struct {
	db *gorm.DB
}

// NewAnnouncementHandler 创建公告处理器
func NewAnnouncementHandler(db *gorm.DB) *AnnouncementHandler {
	return &AnnouncementHandler{db: db}
}

// GetList 获取公告列表
func (h *AnnouncementHandler) GetList(c *gin.Context) {
	var announcements []models.Announcement
	h.db.Preload("Creator").Order("is_pinned DESC, created_at DESC").Find(&announcements)
	c.JSON(http.StatusOK, announcements)
}

// GetActive 获取置顶公告（用于首页展示）
func (h *AnnouncementHandler) GetActive(c *gin.Context) {
	var announcements []models.Announcement
	h.db.Where("is_pinned = ?", true).Preload("Creator").Order("created_at DESC").Find(&announcements)
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
	Title    string `json:"title" binding:"required"`
	Content  string `json:"content" binding:"required"`
	IsPinned bool   `json:"is_pinned"`
}

// Create 创建公告（仅管理员）
func (h *AnnouncementHandler) Create(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var input CreateAnnouncementInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	announcement := models.Announcement{
		Title:     input.Title,
		Content:   input.Content,
		IsPinned:  input.IsPinned,
		CreatedBy: userID.(uint),
	}

	if err := h.db.Create(&announcement).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建公告失败"})
		return
	}

	// 管理员创建公告，经验+1
	h.db.Model(&models.User{}).Where("id = ?", userID).UpdateColumn("admin_exp", gorm.Expr("COALESCE(admin_exp, 0) + 1"))

	h.db.Preload("Creator").First(&announcement, announcement.ID)
	c.JSON(http.StatusCreated, announcement)
}

// UpdateAnnouncementInput 更新公告输入
type UpdateAnnouncementInput struct {
	Title    string `json:"title"`
	Content  string `json:"content"`
	IsPinned *bool  `json:"is_pinned"`
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
	if input.Title != "" {
		updates["title"] = input.Title
	}
	if input.Content != "" {
		updates["content"] = input.Content
	}
	if input.IsPinned != nil {
		updates["is_pinned"] = *input.IsPinned
	}

	h.db.Model(&announcement).Updates(updates)
	h.db.Preload("Creator").First(&announcement, id)
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

// GetUnread 获取当前用户未读公告
func (h *AnnouncementHandler) GetUnread(c *gin.Context) {
	userID, exists := c.Get("user_id")
	uid, ok := userID.(uint)
	if !exists || !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "无效的用户身份"})
		return
	}

	var announcements []models.Announcement
	if err := h.db.Where("id NOT IN (SELECT announcement_id FROM announcement_reads WHERE user_id = ?)", uid).
		Order("created_at DESC").Find(&announcements).Error; err != nil {
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
