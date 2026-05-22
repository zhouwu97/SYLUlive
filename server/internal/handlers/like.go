package handlers

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// LikeHandler 点赞处理器
type LikeHandler struct {
	db *gorm.DB
}

// NewLikeHandler 创建点赞处理器
func NewLikeHandler(db *gorm.DB) *LikeHandler {
	return &LikeHandler{db: db}
}

// LikeInput 点赞输入
type LikeInput struct {
	Type string `json:"type" binding:"required"` // post/reply
}

// LikePost 点赞帖子
func (h *LikeHandler) LikePost(c *gin.Context) {
	userID, _ := c.Get("user_id")
	postIDStr := c.Param("id")
	postID, err := strconv.ParseUint(postIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return
	}

	// 检查是否已点赞
	var existing models.Like
	if err := h.db.Where("user_id = ? AND target_type = ? AND target_id = ?", userID, "post", postID).First(&existing).Error; err == nil {
		c.JSON(http.StatusOK, gin.H{"message": "已点赞"})
		return
	}

	like := models.Like{
		UserID:     userID.(uint),
		TargetType: "post",
		TargetID:   uint(postID),
	}
	h.db.Create(&like)
	h.db.Model(&models.Post{}).Where("id = ?", postID).UpdateColumn("like_count", gorm.Expr("like_count + 1"))
	c.JSON(http.StatusCreated, like)
}

// UnlikePost 取消点赞帖子
func (h *LikeHandler) UnlikePost(c *gin.Context) {
	userID, _ := c.Get("user_id")
	postIDStr := c.Param("id")
	postID, err := strconv.ParseUint(postIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return
	}

	if err := h.db.Where("user_id = ? AND target_type = ? AND target_id = ?", userID, "post", postID).Delete(&models.Like{}).Error; err == nil {
		h.db.Model(&models.Post{}).Where("id = ?", postID).UpdateColumn("like_count", gorm.Expr("GREATEST(like_count - 1, 0)"))
	}
	c.JSON(http.StatusOK, gin.H{"message": "已取消点赞"})
}

// LikeReply 点赞回复
func (h *LikeHandler) LikeReply(c *gin.Context) {
	userID, _ := c.Get("user_id")
	replyIDStr := c.Param("id")
	replyID, err := strconv.ParseUint(replyIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的回复ID"})
		return
	}

	var existing models.Like
	if err := h.db.Where("user_id = ? AND target_type = ? AND target_id = ?", userID, "reply", replyID).First(&existing).Error; err == nil {
		c.JSON(http.StatusOK, gin.H{"message": "已点赞"})
		return
	}

	like := models.Like{
		UserID:     userID.(uint),
		TargetType: "reply",
		TargetID:   uint(replyID),
	}
	h.db.Create(&like)
	h.db.Model(&models.Reply{}).Where("id = ?", replyID).UpdateColumn("like_count", gorm.Expr("like_count + 1"))
	c.JSON(http.StatusCreated, like)
}

// UnlikeReply 取消点赞回复
func (h *LikeHandler) UnlikeReply(c *gin.Context) {
	userID, _ := c.Get("user_id")
	replyIDStr := c.Param("id")
	replyID, err := strconv.ParseUint(replyIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的回复ID"})
		return
	}

	if err := h.db.Where("user_id = ? AND target_type = ? AND target_id = ?", userID, "reply", replyID).Delete(&models.Like{}).Error; err == nil {
		h.db.Model(&models.Reply{}).Where("id = ?", replyID).UpdateColumn("like_count", gorm.Expr("GREATEST(like_count - 1, 0)"))
	}
	c.JSON(http.StatusOK, gin.H{"message": "已取消点赞"})
}
