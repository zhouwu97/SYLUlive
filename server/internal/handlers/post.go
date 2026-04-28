package handlers

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"xiaoyuan/internal/models"
)

// PostHandler 帖子处理器
type PostHandler struct {
	db *gorm.DB
}

// NewPostHandler 创建帖子处理器
func NewPostHandler(db *gorm.DB) *PostHandler {
	return &PostHandler{db: db}
}

// GetList 获取帖子列表
func (h *PostHandler) GetList(c *gin.Context) {
	boardIDStr := c.Query("board")
	postType := c.Query("type")
	sort := c.DefaultQuery("sort", "time")
	pageStr := c.DefaultQuery("page", "1")
	limitStr := c.DefaultQuery("limit", "20")

	page, _ := strconv.Atoi(pageStr)
	limit, _ := strconv.Atoi(limitStr)
	if page < 1 {
		page = 1
	}
	if limit < 1 || limit > 50 {
		limit = 20
	}

	query := h.db.Model(&models.Post{}).Where("status != ?", models.PostStatusDeleted).Preload("Author").Preload("Images").Preload("Images.File")

	if boardIDStr != "" {
		boardID, err := strconv.Atoi(boardIDStr)
		if err == nil {
			query = query.Where("board_id = ?", boardID)
		}
	}

	if postType != "" {
		query = query.Where("post_type = ?", postType)
	}

	// 排序
	switch sort {
	case "price":
		query = query.Order("price ASC")
	case "score":
		query = query.Order("created_at DESC")
	default:
		query = query.Order("created_at DESC")
	}

	var posts []models.Post
	var total int64

	query.Count(&total)
	query.Offset((page - 1) * limit).Limit(limit).Find(&posts)

	c.JSON(http.StatusOK, gin.H{
		"posts": posts,
		"total": total,
		"page":  page,
		"limit": limit,
	})
}

// CreatePostInput 创建帖子输入
type CreatePostInput struct {
	Title    string  `form:"title"`
	Content  string  `form:"content" binding:"required"`
	BoardID  int     `form:"board_id" binding:"required"`
	PostType string  `form:"post_type"`
	Price    float64 `form:"price"`
	Contact  string  `form:"contact"`
}

// Create 创建帖子
func (h *PostHandler) Create(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var input CreatePostInput
	if err := c.ShouldBind(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 骗子曝光板块暂不开放
	if input.BoardID == int(models.BoardScam) {
		c.JSON(http.StatusForbidden, gin.H{"error": "此功能即将开放"})
		return
	}

	post := models.Post{
		Title:    input.Title,
		Content:  input.Content,
		BoardID:  models.BoardID(input.BoardID),
		AuthorID: userID.(uint),
		PostType: input.PostType,
		Price:    input.Price,
		Contact:  input.Contact,
		Status:   models.PostStatusNormal,
	}

	if err := h.db.Create(&post).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建帖子失败"})
		return
	}

	// 处理图片
	fileIDs := c.PostForm("file_ids")
	if fileIDs != "" {
		ids := strings.Split(fileIDs, ",")
		for i, idStr := range ids {
			fileID, err := strconv.ParseUint(idStr, 10, 64)
			if err == nil {
				postImage := models.PostImage{
					PostID:    post.ID,
					FileID:    uint(fileID),
					SortOrder: i,
				}
				h.db.Create(&postImage)
			}
		}
	}

	h.db.Preload("Author").Preload("Images").Preload("Images.File").First(&post, post.ID)
	c.JSON(http.StatusCreated, post)
}

// GetOne 获取帖子详情
func (h *PostHandler) GetOne(c *gin.Context) {
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return
	}

	var post models.Post
	if err := h.db.Preload("Author").Preload("Images").Preload("Images.File").First(&post, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}

	c.JSON(http.StatusOK, post)
}

// UpdatePostInput 更新帖子输入
type UpdatePostInput struct {
	Title   string `form:"title"`
	Content string `form:"content"`
	Price   float64 `form:"price"`
	Contact string `form:"contact"`
}

// Update 更新帖子
func (h *PostHandler) Update(c *gin.Context) {
	userID, _ := c.Get("user_id")
	role, _ := c.Get("role")
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return
	}

	var post models.Post
	if err := h.db.First(&post, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}

	// 只有作者或管理员可以更新
	if post.AuthorID != userID.(uint) && role != "admin" && role != "super_admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		return
	}

	var input UpdatePostInput
	if err := c.ShouldBind(&input); err != nil {
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
	if input.Price > 0 {
		updates["price"] = input.Price
	}
	if input.Contact != "" {
		updates["contact"] = input.Contact
	}

	h.db.Model(&post).Updates(updates)
	h.db.Preload("Author").Preload("Images").Preload("Images.File").First(&post, id)
	c.JSON(http.StatusOK, post)
}

// Delete 删除帖子
func (h *PostHandler) Delete(c *gin.Context) {
	userID, _ := c.Get("user_id")
	role, _ := c.Get("role")
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return
	}

	var post models.Post
	if err := h.db.First(&post, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}

	// 只有作者或管理员可以删除
	if post.AuthorID != userID.(uint) && role != "admin" && role != "super_admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		return
	}

	h.db.Model(&post).Update("status", models.PostStatusDeleted)

	// 记录管理员操作
	if role == "admin" || role == "super_admin" {
		log := models.AdminActionLog{
			AdminID:    userID.(uint),
			Action:     "delete_post",
			TargetType: "post",
			TargetID:   uint(id),
			Detail:     fmt.Sprintf("删除帖子: %s", post.Title),
		}
		h.db.Create(&log)
	}

	c.JSON(http.StatusOK, gin.H{"message": "删除成功"})
}