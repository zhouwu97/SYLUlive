package handlers

import (
	"errors"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"shenliyuan/internal/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// ReplyHandler 回复处理器
type ReplyHandler struct {
	db                *gorm.DB
	jpushAppKey       string
	jpushMasterSecret string
}

// NewReplyHandler 创建回复处理器
func NewReplyHandler(db *gorm.DB, jpushAppKey, jpushMasterSecret string) *ReplyHandler {
	return &ReplyHandler{
		db:                db,
		jpushAppKey:       jpushAppKey,
		jpushMasterSecret: jpushMasterSecret,
	}
}

// GetList 获取回复列表。
//
// 支持 ?sort=hot|latest（默认 hot）。hot 只排序一级评论线程；
// 所有子回复始终按 created_at ASC, id ASC 组装在所属根评论之后。
// 非法 sort 直接 400，不静默回退。
func (h *ReplyHandler) GetList(c *gin.Context) {
	postIDStr := c.Param("id")
	postID, err := strconv.ParseUint(postIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return
	}

	mode, ok := services.ValidCommentSort(c.Query("sort"))
	if !ok {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的评论排序方式"})
		return
	}

	var replies []models.Reply
	if err := h.db.Where("post_id = ? AND status = ?", postID, models.ReplyStatusNormal).
		Preload("Author").Preload("Images").Preload("Images.File").
		Find(&replies).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取回复列表失败"})
		return
	}

	replies = orderReplyThreads(replies, mode, time.Now())

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

// orderReplyThreads 将平铺回复组装成线程顺序：
// 一级评论按 mode 排序（hot/latest），每个根评论的子回复按 created_at ASC, id ASC。
func orderReplyThreads(replies []models.Reply, mode services.CommentSort, now time.Time) []models.Reply {
	// 分离 root / child。
	roots := make([]services.CommentRankCandidate, 0, len(replies))
	childrenByParent := make(map[uint][]models.Reply)
	for _, r := range replies {
		if r.ParentReplyID == nil {
			roots = append(roots, services.CommentRankCandidate{Reply: r})
		} else {
			childrenByParent[*r.ParentReplyID] = append(childrenByParent[*r.ParentReplyID], r)
		}
	}
	for i := range roots {
		roots[i].ChildReplyCount = len(childrenByParent[roots[i].Reply.ID])
	}

	rootByID := make(map[uint]models.Reply, len(roots))
	for _, c := range roots {
		rootByID[c.Reply.ID] = c.Reply
	}

	orderedRootIDs := services.RankRootReplies(roots, mode, now)

	ordered := make([]models.Reply, 0, len(replies))
	for _, rootID := range orderedRootIDs {
		ordered = append(ordered, rootByID[rootID])
		children := childrenByParent[rootID]
		sort.SliceStable(children, func(i, j int) bool {
			if !children[i].CreatedAt.Equal(children[j].CreatedAt) {
				return children[i].CreatedAt.Before(children[j].CreatedAt)
			}
			return children[i].ID < children[j].ID
		})
		ordered = append(ordered, children...)
	}
	return ordered
}

// CreateReplyInput 创建回复输入
type CreateReplyInput struct {
	Content       string `form:"content"`
	StickerID     string `form:"sticker_id"`
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
	input.Content = strings.TrimSpace(input.Content)
	input.StickerID = strings.TrimSpace(input.StickerID)
	fileIDs := c.PostForm("file_ids")
	parsedFileIDs, err := services.ParseImageFileIDs(fileIDs)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if input.Content == "" && input.StickerID == "" && len(parsedFileIDs) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "回复内容不能为空"})
		return
	}
	if input.StickerID != "" {
		if !IsValidStickerID(input.StickerID) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "表情不存在"})
			return
		}
	}
	if input.StickerID != "" && len(parsedFileIDs) > 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "表情回复不能同时包含图片"})
		return
	}

	// 检查帖子是否存在
	var post models.Post
	if err := h.db.First(&post, postID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}
	if post.Status != models.PostStatusNormal {
		c.JSON(http.StatusConflict, gin.H{"error": "该帖子当前不允许回复"})
		return
	}

	// 如果有父回复，检查是否是一层嵌套
	if input.ParentReplyID != nil {
		var parentReply models.Reply
		if err := h.db.First(&parentReply, input.ParentReplyID).Error; err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "父回复不存在"})
			return
		} else {
			if parentReply.PostID != uint(postID) || parentReply.Status != models.ReplyStatusNormal {
				c.JSON(http.StatusBadRequest, gin.H{"error": "父回复不属于当前帖子或已不可回复"})
				return
			}
			if parentReply.ParentReplyID != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "不支持多层嵌套"})
				return
			}
		}
	}

	var stickerID *string
	if input.StickerID != "" {
		stickerID = &input.StickerID
		if input.Content == "" {
			// 旧客户端按普通评论展示纯表情的文本回退。
			input.Content = stickerFallbackText
		}
	}
	reply := models.Reply{
		PostID:        uint(postID),
		ParentReplyID: input.ParentReplyID,
		AuthorID:      userID.(uint),
		Content:       input.Content,
		StickerID:     stickerID,
		Status:        models.ReplyStatusNormal,
		CreatedAt:     time.Now(),
	}

	// 回复、回复图片和帖子活跃统计必须原子提交，避免列表出现已显示回复却没有刷新活跃时间的状态。
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if _, err := services.ValidateImageFileIDs(tx, parsedFileIDs, 9, userID.(uint)); err != nil {
			return err
		}
		if err := services.ClaimPublicImageFiles(tx, parsedFileIDs); err != nil {
			return err
		}
		if err := tx.Create(&reply).Error; err != nil {
			return err
		}
		if len(parsedFileIDs) > 0 {
			for i, fileID := range parsedFileIDs {
				if err := tx.Create(&models.ReplyImage{ReplyID: reply.ID, FileID: fileID, SortOrder: i}).Error; err != nil {
					return err
				}
			}
		}
		return tx.Model(&models.Post{}).Where("id = ?", postID).Updates(map[string]interface{}{
			"reply_count":      gorm.Expr("reply_count + 1"),
			"last_activity_at": reply.CreatedAt,
		}).Error
	}); err != nil {
		if errors.Is(err, services.ErrInvalidImageFileReference) {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建回复失败"})
		return
	}

	// 尝试增加每日首评经验：全局 +3，若被评论帖子属于水帖版块则再 +3 版块经验
	awards := make([]models.ExpAward, 0, 2)
	awarded, globalAward, expErr := services.AwardDailyGlobalExp(h.db, userID.(uint), services.GlobalActionReplyDaily, services.GlobalExpReplyDaily, "reply", reply.ID)
	if expErr != nil {
		// 经验失败不影响评论成功，仅记日志
		log.Printf("[EXP_AWARD] global reply_daily failed user=%v reply_id=%d err=%v", userID, reply.ID, expErr)
	} else if awarded && globalAward != nil {
		awards = append(awards, *globalAward)
	}

	if post.BoardID == models.BoardShuitie && post.ContentKind != models.PostContentKindPoll && post.PostType != "" {
		var section models.WaterSection
		if secErr := h.db.Where("slug = ?", post.PostType).First(&section).Error; secErr == nil && section.ID != 0 {
			secAwarded, secAward, secErr := services.AwardDailySectionExp(h.db, userID.(uint), section.ID, section.Slug, section.Title, services.GlobalActionReplyDaily, services.GlobalExpReplyDaily, "reply", reply.ID)
			if secErr != nil {
				log.Printf("[EXP_AWARD] section reply_daily failed user=%v section=%d reply_id=%d err=%v", userID, section.ID, reply.ID, secErr)
			} else if secAwarded && secAward != nil {
				awards = append(awards, *secAward)
			}
		}
	}

	if len(awards) > 0 {
		reply.ExpAwards = awards
		for _, award := range awards {
			if award.Scope == "global" {
				reply.ExpEarned = award.Exp
			}
		}
	}

	// 发送通知（数据库 + 极光推送）
	contentPreview := utils.TruncateGraphemes(input.Content, 80)
	if contentPreview == "" && len(parsedFileIDs) > 0 {
		contentPreview = "[图片]"
	}
	if input.ParentReplyID != nil {
		// 回复别人的评论 → 通知被回复的评论作者
		var parentReply models.Reply
		if err := h.db.First(&parentReply, *input.ParentReplyID).Error; err == nil {
			notifyUserID := parentReply.AuthorID
			if err := CreateReplyNotification(h.db, notifyUserID, userID.(uint), reply.ID, uint(postID), contentPreview); err != nil {
				log.Printf("[DB_ERROR] 创建回复通知失败: reply_id=%d user_id=%d err=%v", reply.ID, notifyUserID, err)
			}
			SendJPushNotification(h.jpushAppKey, h.jpushMasterSecret, h.db, notifyUserID, userID.(uint), reply.ID, uint(postID), contentPreview)
		}
	} else {
		// 直接回复帖子 → 通知帖子作者
		if err := CreateReplyNotification(h.db, post.AuthorID, userID.(uint), reply.ID, uint(postID), contentPreview); err != nil {
			log.Printf("[DB_ERROR] 创建帖子回复通知失败: reply_id=%d user_id=%d err=%v", reply.ID, post.AuthorID, err)
		}
		SendJPushNotification(h.jpushAppKey, h.jpushMasterSecret, h.db, post.AuthorID, userID.(uint), reply.ID, uint(postID), contentPreview)
	}

	if err := h.db.Preload("Author").Preload("Images").Preload("Images.File").First(&reply, reply.ID).Error; err != nil {
		log.Printf("[DB_WARN] Failed to re-fetch reply with preloads after create: %v", err)
	}
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

	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&reply).Update("status", models.ReplyStatusDeleted).Error; err != nil {
			return err
		}
		return recalculatePostReplyStats(tx, reply.PostID)
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	// 管理员删除他人回复时，记录日志并增加经验
	if reply.AuthorID != userID.(uint) && (role == "admin" || role == "super_admin") {
		var u models.User
		if err := h.db.Select("nickname").First(&u, userID).Error; err != nil {
			u.Nickname = "Unknown Admin"
		}
		if err := h.db.Create(&models.AdminLog{
			AdminID: userID.(uint), AdminName: u.Nickname,
			Action: "删除回复", Target: reply.Content,
		}).Error; err != nil {
			log.Printf("[DB_WARN] Failed to write admin log: %v", err)
		}
		if err := h.db.Model(&models.User{}).Where("id = ?", userID).UpdateColumn("admin_exp", gorm.Expr("COALESCE(admin_exp, 0) + 1")).Error; err != nil {
			log.Printf("[DB_WARN] Failed to update admin_exp: %v", err)
		}
	}

	c.JSON(http.StatusOK, gin.H{"message": "删除成功"})
}

// recalculatePostReplyStats 从有效回复重建帖子回复数及最后活跃时间；调用方必须提供事务。
func recalculatePostReplyStats(tx *gorm.DB, postID uint) error {
	var post models.Post
	if err := tx.Select("id", "created_at").First(&post, postID).Error; err != nil {
		return err
	}
	var count int64
	if err := tx.Model(&models.Reply{}).Where("post_id = ? AND status = ?", postID, models.ReplyStatusNormal).Count(&count).Error; err != nil {
		return err
	}
	lastActivityAt := post.CreatedAt
	var latest models.Reply
	if err := tx.Where("post_id = ? AND status = ?", postID, models.ReplyStatusNormal).Order("created_at DESC, id DESC").First(&latest).Error; err == nil {
		lastActivityAt = latest.CreatedAt
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return err
	}
	return tx.Model(&models.Post{}).Where("id = ?", postID).Updates(map[string]interface{}{
		"reply_count":      int(count),
		"last_activity_at": lastActivityAt,
	}).Error
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
			if err := h.db.Model(&models.Post{}).Select("title", "content").First(&result[i], r.PostID).Error; err != nil {
				result[i].PostTitle = "[原帖已被删除]"
				result[i].PostContent = "..."
			}
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
	if err := h.db.Model(&models.Notification{}).Where("user_id = ? AND type = ? AND is_read = ?", uid, "reply", false).Update("is_read", true).Error; err != nil {
		log.Printf("[DB_WARN] Failed to write side-effect record: %v", err)
	}

	c.JSON(http.StatusOK, result)
}
