package handlers

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// ReplyHandler 回复处理器
type ReplyHandler struct {
	db              *gorm.DB
	jpushAppKey      string
	jpushMasterSecret string
}

// NewReplyHandler 创建回复处理器
func NewReplyHandler(db *gorm.DB, jpushAppKey, jpushMasterSecret string) *ReplyHandler {
	return &ReplyHandler{
		db:              db,
		jpushAppKey:     jpushAppKey,
		jpushMasterSecret: jpushMasterSecret,
	}
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

	if userID, exists := c.Get("user_id"); exists {
		uid := userID.(uint)
		var replyIDs []uint
		for _, r := range replies {
			replyIDs = append(replyIDs, r.ID)
		}
		if len(replyIDs) > 0 {
			var likedReplyIDs []uint
			h.db.Model(&models.Like{}).Where("user_id = ? AND target_type = ? AND target_id IN ?", uid, "reply", replyIDs).Pluck("target_id", &likedReplyIDs)
			likedMap := make(map[uint]bool)
			for _, id := range likedReplyIDs {
				likedMap[id] = true
			}
			for i := range replies {
				if likedMap[replies[i].ID] {
					replies[i].IsLiked = true
				}
			}
		}
	}

	c.JSON(http.StatusOK, replies)
}

// CreateReplyInput 创建回复输入
type CreateReplyInput struct {
	Content       string `form:"content" binding:"required"`
	ParentReplyID *uint  `form:"parent_reply_id"`
	ReplyToUserID *uint  `form:"reply_to_user_id"`
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
	h.db.Model(&models.Post{}).Where("id = ?", postID).Update("reply_count", gorm.Expr("reply_count + 1"))

	// 尝试增加每日首回经验
	now := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.Local)
	expErr := h.db.Transaction(func(tx *gorm.DB) error {
		expLog := models.ExpLog{
			UserID:    userID.(uint),
			Action:    "reply_daily",
			Date:      today,
			ExpEarned: 3,
		}
		if err := tx.Create(&expLog).Error; err != nil {
			return err // 违反唯一约束等，直接回滚
		}
		if err := tx.Model(&models.User{}).Where("id = ?", userID.(uint)).UpdateColumn("exp", gorm.Expr("exp + ?", 3)).Error; err != nil {
			return err
		}
		return nil
	})
	if expErr == nil {
		// 这里虽然用 log，但在实际业务中这代表加分成功
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

	// 发送通知（数据库 + 极光推送）
	contentPreview := input.Content
	if len(contentPreview) > 80 {
		contentPreview = contentPreview[:80] + "..."
	}
	if input.ParentReplyID != nil {
		// 回复别人的评论 → 通知被回复的评论作者
		var parentReply models.Reply
		if err := h.db.First(&parentReply, *input.ParentReplyID).Error; err == nil {
			notifyUserID := parentReply.AuthorID
			if input.ReplyToUserID != nil {
				notifyUserID = *input.ReplyToUserID
			}
			CreateReplyNotification(h.db, notifyUserID, userID.(uint), reply.ID, uint(postID), contentPreview)
			SendJPushNotification(h.jpushAppKey, h.jpushMasterSecret, h.db, notifyUserID, userID.(uint), reply.ID, uint(postID), contentPreview)
		}
	} else {
		// 直接回复帖子 → 通知帖子作者
		CreateReplyNotification(h.db, post.AuthorID, userID.(uint), reply.ID, uint(postID), contentPreview)
		SendJPushNotification(h.jpushAppKey, h.jpushMasterSecret, h.db, post.AuthorID, userID.(uint), reply.ID, uint(postID), contentPreview)
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
	h.db.Model(&models.Post{}).Where("id = ?", reply.PostID).Update("reply_count", gorm.Expr("GREATEST(reply_count - 1, 0)"))

	// 管理员删除他人回复时，记录日志并增加经验
	if reply.AuthorID != userID.(uint) && (role == "admin" || role == "super_admin") {
		var u models.User
		h.db.Select("nickname").First(&u, userID)
		h.db.Create(&models.AdminLog{
			AdminID: userID.(uint), AdminName: u.Nickname,
			Action: "删除回复", Target: reply.Content,
		})
		h.db.Model(&models.User{}).Where("id = ?", userID).UpdateColumn("admin_exp", gorm.Expr("COALESCE(admin_exp, 0) + 1"))
	}

	c.JSON(http.StatusOK, gin.H{"message": "删除成功"})
}

// GetMeList 获取当前用户的所有评论（用于"我的评论"页面）
func (h *ReplyHandler) GetMeList(c *gin.Context) {
	userID, _ := c.Get("user_id")
	limit := 20
	if l := c.Query("limit"); l != "" {
		if parsed, err := strconv.Atoi(l); err == nil && parsed > 0 && parsed <= 100 {
			limit = parsed
		}
	}

	cursor := c.Query("cursor")
	var whereClause string
	var args []interface{}
	whereClause = "replies.author_id = ? AND replies.status = ?"
	args = []interface{}{userID.(uint), models.ReplyStatusNormal}

	if cursor != "" {
		// cursor 格式: created_at|id
		parts := strings.Split(cursor, "|")
		if len(parts) == 2 {
			createdAt, err1 := time.Parse(time.RFC3339, parts[0])
			id, err2 := strconv.ParseUint(parts[1], 10, 64)
			if err1 == nil && err2 == nil {
				whereClause += " AND (replies.created_at < ? OR (replies.created_at = ? AND replies.id < ?))"
				args = append(args, createdAt, createdAt, id)
			}
		}
	}

	var replies []models.Reply
	err := h.db.Model(&models.Reply{}).
		Select("replies.*, posts.title as post_title, posts.content as post_content").
		Joins("LEFT JOIN posts ON posts.id = replies.post_id").
		Where(whereClause, args...).
		Order("replies.created_at DESC, replies.id DESC").
		Limit(limit + 1).
		Find(&replies).Error
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}

	hasMore := len(replies) > limit
	if hasMore {
		replies = replies[:limit]
	}

	var nextCursor string
	if hasMore && len(replies) > 0 {
		last := replies[len(replies)-1]
		nextCursor = last.CreatedAt.Format(time.RFC3339) + "|" + strconv.FormatUint(uint64(last.ID), 10)
	}

	// 构造返回数据，包含帖子上下文
	type MyReplyItem struct {
		models.Reply
		PostTitle   string `json:"post_title"`
		PostContent string `json:"post_content"`
	}
	result := make([]MyReplyItem, len(replies))
	for i, r := range replies {
		result[i] = MyReplyItem{
			Reply:       r,
			PostTitle:   "",
			PostContent: "",
		}
		if r.PostID != 0 {
			h.db.Model(&models.Post{}).Select("title", "content").First(&result[i], r.PostID)
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"replies":     result,
		"next_cursor": nextCursor,
	})
}

// GetReceivedList 获取收到的回复（别人回复了我的帖子或我的评论）
func (h *ReplyHandler) GetReceivedList(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	// 查询通知表中类型为 reply 且目标用户是当前用户的记录
	var notifications []models.Notification
	h.db.Where("user_id = ? AND type = ?", uid, "reply").
		Order("created_at DESC").
		Limit(50).
		Find(&notifications)

	// 获取关联的回复详情
	type ReceivedReplyItem struct {
		models.Reply
		PostTitle string `json:"post_title"`
		IsRead    bool   `json:"is_read"`
	}

	result := make([]ReceivedReplyItem, 0, len(notifications))
	for _, n := range notifications {
		var reply models.Reply
		if err := h.db.Preload("Author").First(&reply, n.RelatedID).Error; err != nil {
			continue
		}
		var postTitle string
		var post models.Post
		if err := h.db.Select("title").First(&post, reply.PostID).Error; err == nil {
			postTitle = post.Title
		}
		result = append(result, ReceivedReplyItem{
			Reply:     reply,
			PostTitle: postTitle,
			IsRead:    n.IsRead,
		})
	}

	// 标记所有回复通知为已读
	h.db.Model(&models.Notification{}).Where("user_id = ? AND type = ? AND is_read = ?", uid, "reply", false).Update("is_read", true)

	c.JSON(http.StatusOK, result)
}
