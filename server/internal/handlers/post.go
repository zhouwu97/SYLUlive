package handlers

import (
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
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
	searchQuery := strings.TrimSpace(strings.ToLower(c.Query("q")))
	sort := c.DefaultQuery("sort", "time")
	pageStr := c.DefaultQuery("page", "1")
	limitStr := c.DefaultQuery("limit", "20")
	sinceStr := c.Query("since") // 增量拉取：只返回此时间之后更新的帖子

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

	// 增量查询：只返回 since 时间之后更新的帖子
	if sinceStr != "" {
		sinceTime, err := time.Parse(time.RFC3339, sinceStr)
		if err == nil {
			query = query.Where("updated_at > ?", sinceTime)
		}
	}

	if searchQuery != "" {
		searchLike := "%" + searchQuery + "%"
		query = query.Where(
			"(LOWER(title) LIKE ? OR LOWER(content) LIKE ?)",
			searchLike,
			searchLike,
		)
		query = query.Order(clause.Expr{
			SQL: `CASE
				WHEN LOWER(title) = ? THEN 0
				WHEN LOWER(title) LIKE ? THEN 1
				WHEN LOWER(title) LIKE ? THEN 2
				WHEN LOWER(content) LIKE ? THEN 3
				ELSE 4
			END,
			POSITION(? IN LOWER(title)),
			CHAR_LENGTH(title)`,
			Vars: []interface{}{
				searchQuery,
				searchQuery + "%",
				searchLike,
				searchLike,
				searchQuery,
			},
		})
	}

	// 排序
	switch sort {
	case "price":
		query = query.Order("price ASC").Order("created_at DESC")
	case "score":
		query = query.Order("created_at DESC")
	default:
		query = query.Order("created_at DESC")
	}

	var posts []models.Post
	var total int64

	query.Count(&total)
	query.Offset((page - 1) * limit).Limit(limit).Find(&posts)

	if userID, exists := c.Get("user_id"); exists {
		uid := userID.(uint)
		var postIDs []uint
		for _, p := range posts {
			postIDs = append(postIDs, p.ID)
		}
		if len(postIDs) > 0 {
			var likedPostIDs []uint
			h.db.Model(&models.Like{}).Where("user_id = ? AND target_type = ? AND target_id IN ?", uid, "post", postIDs).Pluck("target_id", &likedPostIDs)
			likedMap := make(map[uint]bool)
			for _, id := range likedPostIDs {
				likedMap[id] = true
			}
			for i := range posts {
				if likedMap[posts[i].ID] {
					posts[i].IsLiked = true
				}
			}
		}
	}

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

	var user models.User
	if err := h.db.Select("id", "edu_bound").First(&user, userID).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "用户不存在"})
		return
	}
	if models.BoardID(input.BoardID) == models.BoardMarket && !user.EduBound {
		c.JSON(http.StatusForbidden, gin.H{"error": "毕业用户仅可发布普通帖子，不能在集市发帖"})
		return
	}

	// 先创建帖子
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
		log.Printf("创建帖子失败: %v (user_id=%v, board_id=%v, content_len=%d)", err, userID, input.BoardID, len(input.Content))
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("创建帖子失败: %v", err)})
		return
	}

	// 尝试增加每日首发经验
	today := time.Now().Truncate(24 * time.Hour)
	expErr := h.db.Transaction(func(tx *gorm.DB) error {
		expLog := models.ExpLog{
			UserID:    userID.(uint),
			Action:    "post_daily",
			Date:      today,
			ExpEarned: 5,
		}
		if err := tx.Create(&expLog).Error; err != nil {
			return err // 违反唯一约束等，直接回滚
		}
		if err := tx.Model(&models.User{}).Where("id = ?", userID.(uint)).UpdateColumn("exp", gorm.Expr("exp + ?", 5)).Error; err != nil {
			return err
		}
		return nil
	})
	if expErr == nil {
		log.Printf("用户 %v 获得每日首发经验 5 点", userID)
	}

	// 处理图片 - 从 multipart form 读取 file_ids
	fileIDs := c.PostForm("file_ids")
	if fileIDs == "" {
		// 降级：直接从 Request.MultipartForm 读取
		if c.Request.MultipartForm != nil {
			if vals, ok := c.Request.MultipartForm.Value["file_ids"]; ok && len(vals) > 0 {
				fileIDs = vals[0]
			}
		}
	}
	log.Printf("创建帖子 file_ids=%q (post_id=%d)", fileIDs, post.ID)
	if fileIDs != "" {
		ids := strings.Split(fileIDs, ",")
		for i, idStr := range ids {
			fileID, err := strconv.ParseUint(idStr, 10, 64)
			if err != nil {
				log.Printf("解析 file_id 失败: %q → %v", idStr, err)
				continue
			}
			postImage := models.PostImage{
				PostID:    post.ID,
				FileID:    uint(fileID),
				SortOrder: i,
			}
			if err := h.db.Create(&postImage).Error; err != nil {
				log.Printf("创建 PostImage 失败: post_id=%d, file_id=%d, err=%v", post.ID, fileID, err)
			}
		}
	}

	h.db.Preload("Author").Preload("Images").Preload("Images.File").First(&post, post.ID)

	// 集市发帖通知所有用户
	if post.BoardID == models.BoardMarket {
		go CreateMarketPostNotification(h.db, post.ID, post.Title, post.Price, userID.(uint))
	}

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

	// 增加观看次数
	h.db.Model(&post).UpdateColumn("view_count", gorm.Expr("view_count + 1"))
	post.ViewCount++

	if userID, exists := c.Get("user_id"); exists {
		var count int64
		h.db.Model(&models.Like{}).Where("user_id = ? AND target_type = ? AND target_id = ?", userID.(uint), "post", post.ID).Count(&count)
		post.IsLiked = count > 0
	}

	c.JSON(http.StatusOK, post)
}

// UpdatePostInput 更新帖子输入
type UpdatePostInput struct {
	Title    string  `form:"title"`
	Content  string  `form:"content"`
	PostType string  `form:"post_type"`
	Price    float64 `form:"price"`
	Contact  string  `form:"contact"`
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

	var user models.User
	if err := h.db.Select("id", "edu_bound").First(&user, userID).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "用户不存在"})
		return
	}
	if post.BoardID == models.BoardMarket && !user.EduBound {
		c.JSON(http.StatusForbidden, gin.H{"error": "毕业用户不能编辑集市帖子"})
		return
	}

	var input UpdatePostInput
	if err := c.ShouldBind(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	updates := map[string]interface{}{
		"title":     input.Title,
		"content":   input.Content,
		"post_type": input.PostType,
		"price":     input.Price,
		"contact":   input.Contact,
	}

	if err := h.db.Model(&post).Updates(updates).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新帖子失败"})
		return
	}

	if fileIDs, exists := c.GetPostForm("file_ids"); exists {
		if err := h.db.Where("post_id = ?", post.ID).Delete(&models.PostImage{}).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "更新帖子图片失败"})
			return
		}
		if strings.TrimSpace(fileIDs) != "" {
			ids := strings.Split(fileIDs, ",")
			for i, idStr := range ids {
				fileID, err := strconv.ParseUint(strings.TrimSpace(idStr), 10, 64)
				if err != nil {
					continue
				}
				postImage := models.PostImage{
					PostID:    post.ID,
					FileID:    uint(fileID),
					SortOrder: i,
				}
				if err := h.db.Create(&postImage).Error; err != nil {
					log.Printf("更新 PostImage 失败: post_id=%d, file_id=%d, err=%v", post.ID, fileID, err)
				}
			}
		}
	}

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

	// 记录管理员操作 & 增加管理员经验
	if role == "admin" || role == "super_admin" {
		var u models.User
		h.db.Select("nickname").First(&u, userID)
		h.db.Create(&models.AdminLog{
			AdminID: userID.(uint), AdminName: u.Nickname,
			Action: "删除帖子", Target: post.Title,
		})
		// 管理员每使用一次管理权限，经验+1
		h.db.Model(&models.User{}).Where("id = ?", userID).UpdateColumn("admin_exp", gorm.Expr("COALESCE(admin_exp, 0) + 1"))
	}

	c.JSON(http.StatusOK, gin.H{"message": "删除成功"})
}
