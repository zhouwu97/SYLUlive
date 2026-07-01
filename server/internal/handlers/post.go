package handlers

import (
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// PostHandler 帖子处理器
type PostHandler struct {
	db                *gorm.DB
	jpushAppKey       string
	jpushMasterSecret string
}

// NewPostHandler 创建帖子处理器
func NewPostHandler(db *gorm.DB, jpushAppKey, jpushMasterSecret string) *PostHandler {
	return &PostHandler{db: db, jpushAppKey: jpushAppKey, jpushMasterSecret: jpushMasterSecret}
}

// Snapshot 帖子快照
type Snapshot struct {
	PostIDs   []uint
	ExpiredAt time.Time
}

var ActiveSnapshots sync.Map // key: session_id (string), value: Snapshot

// GetList 获取帖子列表
func (h *PostHandler) GetList(c *gin.Context) {
	boardIDStr := c.Query("board")
	postType := c.Query("type")
	searchQuery := strings.TrimSpace(strings.ToLower(c.Query("q")))
	sort := c.DefaultQuery("sort", "time")
	pageStr := c.DefaultQuery("page", "1")
	limitStr := c.DefaultQuery("limit", "20")
	sinceStr := c.Query("since")

	scene := c.Query("scene") // refresh 或 loadmore
	sessionID := c.Query("session_id")
	offsetStr := c.Query("offset")

	page, _ := strconv.Atoi(pageStr)
	limit, _ := strconv.Atoi(limitStr)
	offset, _ := strconv.Atoi(offsetStr)
	if page < 1 {
		page = 1
	}
	if limit < 1 || limit > 50 {
		limit = 20
	}

	// 如果是常规分页（没有传入scene或者只是普通请求），默认使用 offset
	if scene == "" && offset == 0 {
		offset = (page - 1) * limit
	}

	var posts []models.Post
	var total int64
	now := time.Now()

	// 如果是加载更多，并且带有有效的 session_id，尝试走快照
	if scene == "loadmore" && sessionID != "" {
		if val, ok := ActiveSnapshots.Load(sessionID); ok {
			snapshot := val.(Snapshot)
			if time.Now().Before(snapshot.ExpiredAt) {
				// 计算切片边界
				end := offset + limit
				if offset < len(snapshot.PostIDs) {
					if end > len(snapshot.PostIDs) {
						end = len(snapshot.PostIDs)
					}
					targetIDs := snapshot.PostIDs[offset:end]

					if len(targetIDs) > 0 {
						var rawPosts []models.Post
						if err := h.db.Model(&models.Post{}).Where("id IN ?", targetIDs).Preload("Author").Preload("Images").Preload("Images.File").Find(&rawPosts).Error; err != nil {
							log.Printf("[DB_ERROR] GetList hot-feed Find failed: %v", err)
						}

						// 重组排序
						postMap := make(map[uint]models.Post)
						for _, p := range rawPosts {
							postMap[p.ID] = p
						}
						for _, id := range targetIDs {
							if p, exists := postMap[id]; exists {
								posts = append(posts, p)
							}
						}
					}

					// 直接返回，不再走正常查询
					h.fillLikes(c, posts)
					if posts == nil {
						posts = []models.Post{}
					}
					c.JSON(http.StatusOK, gin.H{
						"posts":      posts,
						"total":      len(snapshot.PostIDs),
						"page":       page,
						"limit":      limit,
						"session_id": sessionID,
					})
					return
				}
			} else {
				ActiveSnapshots.Delete(sessionID)
			}
		}
	}

	// 走正常的查询（或 refresh 阶段）
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

	if sinceStr != "" {
		sinceTime, err := time.Parse(time.RFC3339, sinceStr)
		if err == nil {
			query = query.Where("updated_at > ?", sinceTime)
		}
	}

	// 关注信息流：仅显示当前用户关注的人发布的帖子
	if sort == "following" {
		rawUserID, exists := c.Get("user_id")
		userID, ok := rawUserID.(uint)
		if !exists || !ok || userID == 0 {
			c.JSON(http.StatusUnauthorized, gin.H{
				"error": "登录后才能查看关注动态",
			})
			return
		}
		followingSubQuery := h.db.
			Model(&models.UserFollow{}).
			Select("following_id").
			Where("follower_id = ?", userID)
		query = query.Where("author_id IN (?)", followingSubQuery)
	}

	if searchQuery != "" {
		searchLike := "%" + searchQuery + "%"
		query = query.Where(
			"(LOWER(title) LIKE ? OR LOWER(content) LIKE ?)",
			searchLike,
			searchLike,
		)
		query = query.Clauses(clause.OrderBy{
			Expression: clause.Expr{
				SQL: `CASE
				WHEN LOWER(title) = ? THEN 0
				WHEN LOWER(title) LIKE ? THEN 1
				WHEN LOWER(title) LIKE ? THEN 2
				WHEN LOWER(content) LIKE ? THEN 3
				ELSE 4
			END ASC,
			CASE
				WHEN is_pinned = ? AND (pinned_until IS NULL OR pinned_until > ?)
				THEN 0 ELSE 1
			END ASC,
			pinned_weight DESC,
			pinned_at DESC NULLS LAST,
			created_at DESC`,
				Vars: []interface{}{
					searchQuery,
					searchQuery + "%",
					searchLike,
					searchLike,
					true,
					now,
				},
				WithoutParentheses: true,
			},
		})
	}

	// 动态算法拦截
	isSnapshotting := false
	if scene == "refresh" && (sort == "all" || sort == "hot") && searchQuery == "" && sinceStr == "" {
		isSnapshotting = true
		if sort == "all" {
			query = applyPinnedOrder(query, now).
				Order("(10.0 + like_count*5 + reply_count*10 + view_count*0.2) / POWER((EXTRACT(EPOCH FROM (NOW() - created_at))/3600.0 + 2), 2) DESC")
		} else if sort == "hot" {
			query = query.Order("(view_count*1 + like_count*20 + reply_count*50) DESC")
		}
	} else {
		// 常规排序
		switch sort {
		case "price":
			query = query.Order("price ASC").Order("created_at DESC")
		case "price_desc":
			query = query.Order("price DESC").Order("created_at DESC")
		case "following":
			query = query.Order("created_at DESC")
		default:
			if searchQuery == "" {
				query = applyPinnedOrder(query, now)
				query = query.Order("created_at DESC")
			}
		}
	}

	query.Session(&gorm.Session{}).Count(&total)

	if isSnapshotting {
		var allIDs []uint
		// 这里必须清除Preload等，单纯Pluck
		snapshotQuery := h.db.Model(&models.Post{}).Where("status != ?", models.PostStatusDeleted)
		if boardIDStr != "" {
			boardID, err := strconv.Atoi(boardIDStr)
			if err == nil {
				snapshotQuery = snapshotQuery.Where("board_id = ?", boardID)
			}
		}
		if postType != "" {
			snapshotQuery = snapshotQuery.Where("post_type = ?", postType)
		}
		if sort == "all" {
			snapshotQuery = applyPinnedOrder(snapshotQuery, now).
				Order("(10.0 + like_count*5 + reply_count*10 + view_count*0.2) / POWER((EXTRACT(EPOCH FROM (NOW() - created_at))/3600.0 + 2), 2) DESC")
		} else if sort == "hot" {
			snapshotQuery = snapshotQuery.Order("(view_count*1 + like_count*20 + reply_count*50) DESC")
		}
		if sort == "hot" {
			snapshotQuery = snapshotQuery.Limit(500)
		}
		snapshotQuery.Pluck("id", &allIDs)

		sessionID = fmt.Sprintf("%d", time.Now().UnixNano())
		ActiveSnapshots.Store(sessionID, Snapshot{
			PostIDs:   allIDs,
			ExpiredAt: time.Now().Add(10 * time.Minute),
		})

		// 自动销毁
		time.AfterFunc(10*time.Minute, func() {
			ActiveSnapshots.Delete(sessionID)
		})

		// 取出第一页
		end := limit
		if end > len(allIDs) {
			end = len(allIDs)
		}
		if len(allIDs) > 0 {
			targetIDs := allIDs[:end]
			var rawPosts []models.Post
			if err := h.db.Model(&models.Post{}).Where("id IN ?", targetIDs).Preload("Author").Preload("Images").Preload("Images.File").Find(&rawPosts).Error; err != nil {
				log.Printf("[DB_ERROR] GetList common feed Find failed: %v", err)
			}

			postMap := make(map[uint]models.Post)
			for _, p := range rawPosts {
				postMap[p.ID] = p
			}
			for _, id := range targetIDs {
				if p, exists := postMap[id]; exists {
					posts = append(posts, p)
				}
			}
		}
	} else {
		// 普通查询分页
		if err := query.Offset(offset).Limit(limit).Find(&posts).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取帖子列表失败"})
			return
		}
	}

	h.fillLikes(c, posts)
	if posts == nil {
		posts = []models.Post{}
	}

	c.JSON(http.StatusOK, gin.H{
		"posts":      posts,
		"total":      total,
		"page":       page,
		"limit":      limit,
		"session_id": sessionID,
	})
}

// 提取共用方法
func (h *PostHandler) fillLikes(c *gin.Context, posts []models.Post) {
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
	now := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.Local)
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
	// 处理图片 - 从 multipart form 读取 file_ids
	fileIDs := c.PostForm("file_ids")
	if fileIDs == "" {
		// 降级1：尝试读取带中括号的形式 (有些客户端会发 file_ids[] )
		fileIDs = c.PostForm("file_ids[]")
	}
	if fileIDs == "" && c.Request.MultipartForm != nil {
		// 降级2：遍历所有 Multipart 键，查找包含 file_ids 的
		for k, vals := range c.Request.MultipartForm.Value {
			if strings.Contains(k, "file_ids") && len(vals) > 0 {
				fileIDs = vals[0]
				break
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

	if err := h.db.Preload("Author").Preload("Images").Preload("Images.File").First(&post, post.ID).Error; err != nil {
		log.Printf("[DB_WARN] Failed to re-fetch post with preloads after create: %v", err)
	}

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

	if err := h.db.Preload("Author").Preload("Images").Preload("Images.File").First(&post, id).Error; err != nil {
		log.Printf("[DB_WARN] Failed to re-fetch post with preloads after update: %v", err)
	}
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

	if err := h.db.Model(&post).Update("status", models.PostStatusDeleted).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	// 记录管理员操作 & 增加管理员经验
	if role == "admin" || role == "super_admin" {
		var u models.User
		h.db.Select("nickname").First(&u, userID)
		if err := h.db.Create(&models.AdminLog{
			AdminID: userID.(uint), AdminName: u.Nickname,
			Action: "删除帖子", Target: post.Title,
		}).Error; err != nil {
			log.Printf("[DB_WARN] Failed to write admin log: %v", err)
		}
		// 管理员每使用一次管理权限，经验+1
		if err := h.db.Model(&models.User{}).Where("id = ?", userID).UpdateColumn("admin_exp", gorm.Expr("COALESCE(admin_exp, 0) + 1")).Error; err != nil {
			log.Printf("[DB_WARN] Failed to update admin_exp: %v", err)
		}
	}

	c.JSON(http.StatusOK, gin.H{"message": "删除成功"})
}
