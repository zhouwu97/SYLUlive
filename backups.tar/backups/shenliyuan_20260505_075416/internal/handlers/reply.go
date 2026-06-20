package handlers

import (
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// ReplyHandler 回复处理器
type ReplyHandler struct {
	db *gorm.DB
}

// NewReplyHandler 创建回复处理器
func NewReplyHandler(db *gorm.DB) *ReplyHandler {
	return &ReplyHandler{db: db}
}

// GetList 获取回复列表
func (h *ReplyHandler) GetList(c *gin.Context) {
	postIDStr := c.Param("id")
	postID, err := strconv.ParseUint(postIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return
	}

	var replies []models.Reply
	h.db.Where("post_id = ? AND status = ?", postID, models.ReplyStatusNormal).
		Preload("Author").Preload("Images").Preload("Images.File").
		Order("created_at ASC").Find(&replies)

	c.JSON(http.StatusOK, replies)
}

// CreateReplyInput 创建回复输入
type CreateReplyInput struct {
	Content       string `form:"content" binding:"required"`
	ParentReplyID *uint  `form:"parent_reply_id"`
}

// Create 创建回复
func (h *ReplyHandler) Create(c *gin.Context) {
	userID, _ := c.Get("user_id")
	postIDStr := c.Param("id")
	postID, err := strconv.ParseUint(postIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return
	}

	var input CreateReplyInput
	if err := c.ShouldBind(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 检查帖子是否存在
	var post models.Post
	if err := h.db.First(&post, postID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}

	// 如果有父回复，检查是否是一层嵌套
	if input.ParentReplyID != nil {
		var parentReply models.Reply
		if err := h.db.First(&parentReply, input.ParentReplyID).Error; err == nil {
			if parentReply.ParentReplyID != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "不支持多层嵌套"})
				return
			}
		}
	}

	reply := models.Reply{
		PostID:        uint(postID),
		ParentReplyID: input.ParentReplyID,
		AuthorID:      userID.(uint),
		Content:       input.Content,
		Status:        models.ReplyStatusNormal,
	}

	if err := h.db.Create(&reply).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建回复失败"})
		return
	}

	// 处理图片
	fileIDs := c.PostForm("file_ids")
	if fileIDs != "" {
		ids := strings.Split(fileIDs, ",")
		for i, idStr := range ids {
			fileID, _ := strconv.ParseUint(idStr, 10, 64)
			replyImage := models.ReplyImage{
				ReplyID:   reply.ID,
				FileID:    uint(fileID),
				SortOrder: i,
			}
			h.db.Create(&replyImage)
		}
	}

	h.db.Preload("Author").Preload("Images").Preload("Images.File").First(&reply, reply.ID)
	c.JSON(http.StatusCreated, reply)
}

// DeleteReplyInput 删除回复输入（软删除）
type DeleteReplyInput struct {
	Hard bool `json:"hard"` // 是否硬删除
}

// Delete 删除回复
func (h *ReplyHandler) Delete(c *gin.Context) {
	userID, _ := c.Get("user_id")
	role, _ := c.Get("role")
	replyIDStr := c.Param("id")
	replyID, err := strconv.ParseUint(replyIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的回复ID"})
		return
	}

	var reply models.Reply
	if err := h.db.First(&reply, replyID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "回复不存在"})
		return
	}

	// 只有作者或管理员可以删除
	if reply.AuthorID != userID.(uint) && role != "admin" && role != "super_admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		return
	}

	h.db.Model(&reply).Update("status", models.ReplyStatusDeleted)
	c.JSON(http.StatusOK, gin.H{"message": "删除成功"})
}
