package handlers

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// TutorialHandler 教程页面处理器
type TutorialHandler struct {
	db *gorm.DB
}

func NewTutorialHandler(db *gorm.DB) *TutorialHandler {
	return &TutorialHandler{db: db}
}

// Get 获取指定页面的教程内容
func (h *TutorialHandler) Get(c *gin.Context) {
	pageKey := c.Param("key")
	var tutorial models.Tutorial
	if err := h.db.Where("page_key = ?", pageKey).First(&tutorial).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "页面不存在"})
		return
	}
	c.JSON(http.StatusOK, tutorial)
}

// Update 管理员更新教程内容
func (h *TutorialHandler) Update(c *gin.Context) {
	pageKey := c.Param("key")
	var req struct {
		Title   string `json:"title" binding:"required"`
		Content string `json:"content" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	// 从 context 获取当前用户 ID（由 AuthMiddleware 注入）
	userID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未登录"})
		return
	}

	var tutorial models.Tutorial
	result := h.db.Where("page_key = ?", pageKey).First(&tutorial)
	if result.Error != nil {
		// 不存在则创建
		tutorial = models.Tutorial{
			PageKey:   pageKey,
			Title:     req.Title,
			Content:   req.Content,
			UpdatedBy: userID.(uint),
		}
		h.db.Create(&tutorial)
	} else {
		// 已存在则更新
		tutorial.Title = req.Title
		tutorial.Content = req.Content
		tutorial.UpdatedBy = userID.(uint)
		h.db.Save(&tutorial)
	}

	c.JSON(http.StatusOK, tutorial)
}
