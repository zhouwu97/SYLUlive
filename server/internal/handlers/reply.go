package handlers

import (
	"errors"
	"log"
	"net/http"
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

// 评论列表分页与子回复上限。
const (
	defaultReplyPageLimit = 20
	maxReplyPageLimit     = 50
	// maxChildrenPerRoot 列表响应中每个根评论最多携带的子回复数；
	// 其余子回复通过 GET /api/posts/:id/replies/:replyId/children 懒加载。
	maxChildrenPerRoot = 50
)

// replyListResponse GetList 的响应结构。
type replyListResponse struct {
	Replies    []models.Reply `json:"replies"`
	Total      int64          `json:"total"`
	NextCursor string         `json:"next_cursor"`
}

// GetList 获取回复列表（根评论游标分页）。
//
// 支持 ?sort=hot|latest（默认 hot）。hot 只排序一级评论线程；
// 所有子回复始终按 created_at ASC, id ASC 组装在所属根评论之后。
// 分页：?cursor=<root_id>&limit=<1..50>，cursor 为上一页最后一个根评论 ID。
//
// 删除的一级评论如果有正常子回复，会作为 tombstone 根返回
// （status=deleted），客户端渲染"该评论已删除"但保留其下讨论。
// total 与帖子 reply_count 口径一致：正常回复数 + tombstone 根数。
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

	limit := defaultReplyPageLimit
	if l := c.Query("limit"); l != "" {
		parsed, perr := strconv.Atoi(l)
		if perr != nil || parsed <= 0 || parsed > maxReplyPageLimit {
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效的分页大小"})
			return
		}
		limit = parsed
	}
	var cursorID uint64
	if cur := c.Query("cursor"); cur != "" {
		parsed, perr := strconv.ParseUint(cur, 10, 64)
		if perr != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效的分页游标"})
			return
		}
		cursorID = parsed
	}

	// 1) 根候选：正常根 + tombstone 根（已删除但仍有正常子回复）。只取排序所需列。
	var rootRows []models.Reply
	if err := h.db.
		Where("post_id = ? AND parent_reply_id IS NULL AND (status = ? OR (status = ? AND EXISTS (SELECT 1 FROM replies c WHERE c.parent_reply_id = replies.id AND c.status = ?)))",
			postID, models.ReplyStatusNormal, models.ReplyStatusDeleted, models.ReplyStatusNormal).
		Order("id ASC").
		Find(&rootRows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取回复列表失败"})
		return
	}

	// 2) 每个根的真实子回复总数。
	childCounts := map[uint]int64{}
	var countRows []struct {
		ParentReplyID uint
		N             int64
	}
	if err := h.db.Model(&models.Reply{}).
		Select("parent_reply_id, COUNT(*) as n").
		Where("post_id = ? AND status = ? AND parent_reply_id IS NOT NULL", postID, models.ReplyStatusNormal).
		Group("parent_reply_id").Scan(&countRows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取回复列表失败"})
		return
	}
	for _, row := range countRows {
		childCounts[row.ParentReplyID] = row.N
	}

	// 3) 根排序（hot/latest 只作用于一级评论线程）。
	now := time.Now()
	candidates := make([]services.CommentRankCandidate, 0, len(rootRows))
	tombstones := 0
	for _, r := range rootRows {
		if r.Status == models.ReplyStatusDeleted {
			tombstones++
		}
		candidates = append(candidates, services.CommentRankCandidate{
			Reply:           r,
			ChildReplyCount: int(childCounts[r.ID]),
		})
	}
	orderedRootIDs := services.RankRootReplies(candidates, mode, now)

	// 4) 游标分页。cursor 找不到（根被删/排序漂移）时从第一页开始，客户端按 id 去重。
	start := 0
	if cursorID != 0 {
		start = -1
		for i, id := range orderedRootIDs {
			if id == uint(cursorID) {
				start = i + 1
				break
			}
		}
		if start < 0 {
			start = 0
		}
	}
	end := start + limit
	if end > len(orderedRootIDs) {
		end = len(orderedRootIDs)
	}
	pageRootIDs := orderedRootIDs[start:end]
	nextCursor := ""
	if end < len(orderedRootIDs) && len(pageRootIDs) > 0 {
		nextCursor = strconv.FormatUint(uint64(pageRootIDs[len(pageRootIDs)-1]), 10)
	}

	// 5) 组装本页：根（含 preload）+ 其正常子回复（ASC，每根最多 maxChildrenPerRoot 条）。
	pageRoots := make([]models.Reply, 0, len(pageRootIDs))
	if len(pageRootIDs) > 0 {
		if err := h.db.Where("id IN ?", pageRootIDs).
			Preload("Author").Preload("Images").Preload("Images.File").
			Find(&pageRoots).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取回复列表失败"})
			return
		}
	}
	pageRootByID := map[uint]models.Reply{}
	for _, r := range pageRoots {
		pageRootByID[r.ID] = r
	}
	childrenByParent := map[uint][]models.Reply{}
	if len(pageRootIDs) > 0 {
		var children []models.Reply
		if err := h.db.Where("post_id = ? AND status = ? AND parent_reply_id IN ?",
			postID, models.ReplyStatusNormal, pageRootIDs).
			Order("created_at ASC, id ASC").
			Preload("Author").Preload("Images").Preload("Images.File").
			Find(&children).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取回复列表失败"})
			return
		}
		for _, ch := range children {
			childrenByParent[*ch.ParentReplyID] = append(childrenByParent[*ch.ParentReplyID], ch)
		}
	}

	ordered := make([]models.Reply, 0, len(pageRootIDs))
	for _, rid := range pageRootIDs {
		root := pageRootByID[rid]
		root.ChildReplyCount = int(childCounts[rid])
		ordered = append(ordered, root)
		kids := childrenByParent[rid]
		if len(kids) > maxChildrenPerRoot {
			kids = kids[:maxChildrenPerRoot]
		}
		ordered = append(ordered, kids...)
	}

	// 6) 登录用户点赞状态（仅本页回复）。
	if userID, exists := c.Get("user_id"); exists {
		uid := userID.(uint)
		var replyIDs []uint
		for _, r := range ordered {
			replyIDs = append(replyIDs, r.ID)
		}
		if len(replyIDs) > 0 {
			var likedReplyIDs []uint
			h.db.Model(&models.Like{}).Where("user_id = ? AND target_type = ? AND target_id IN ?", uid, "reply", replyIDs).Pluck("target_id", &likedReplyIDs)
			likedMap := make(map[uint]bool)
			for _, id := range likedReplyIDs {
				likedMap[id] = true
			}
			for i := range ordered {
				if likedMap[ordered[i].ID] {
					ordered[i].IsLiked = true
				}
			}
		}
	}

	// 7) total 与帖子 reply_count 口径一致：正常回复 + tombstone 根。
	var normalTotal int64
	if err := h.db.Model(&models.Reply{}).
		Where("post_id = ? AND status = ?", postID, models.ReplyStatusNormal).
		Count(&normalTotal).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取回复列表失败"})
		return
	}

	c.JSON(http.StatusOK, replyListResponse{
		Replies:    ordered,
		Total:      normalTotal + int64(tombstones),
		NextCursor: nextCursor,
	})
}

// GetChildren 懒加载某条根评论的子回复（created_at ASC 游标分页）。
func (h *ReplyHandler) GetChildren(c *gin.Context) {
	postIDStr := c.Param("id")
	postID, err := strconv.ParseUint(postIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return
	}
	replyIDStr := c.Param("replyId")
	replyID, err := strconv.ParseUint(replyIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的评论ID"})
		return
	}

	limit := 50
	if l := c.Query("limit"); l != "" {
		parsed, perr := strconv.Atoi(l)
		if perr != nil || parsed <= 0 || parsed > 100 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效的分页大小"})
			return
		}
		limit = parsed
	}

	var root models.Reply
	if err := h.db.Select("id", "post_id", "status").First(&root, replyID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "评论不存在"})
		return
	}
	// URL 中的 postId 必须与根评论所属帖子一致，接口语义不允许跨帖取子回复。
	if root.PostID != uint(postID) {
		c.JSON(http.StatusNotFound, gin.H{"error": "评论不存在"})
		return
	}

	query := h.db.Where("parent_reply_id = ? AND status = ?", replyID, models.ReplyStatusNormal)
	if cursor := c.Query("cursor"); cursor != "" {
		parts := strings.Split(cursor, "|")
		if len(parts) == 2 {
			// RFC3339Nano：秒级精度会让游标条目在下一页重复出现。
			createdAt, err1 := time.Parse(time.RFC3339Nano, parts[0])
			id, err2 := strconv.ParseUint(parts[1], 10, 64)
			if err1 == nil && err2 == nil {
				query = query.Where("(created_at > ? OR (created_at = ? AND id > ?))", createdAt, createdAt, id)
			}
		}
	}

	var children []models.Reply
	if err := query.Preload("Author").Preload("Images").Preload("Images.File").
		Order("created_at ASC, id ASC").
		Limit(limit + 1).
		Find(&children).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取子回复失败"})
		return
	}
	hasMore := len(children) > limit
	if hasMore {
		children = children[:limit]
	}
	nextCursor := ""
	if hasMore && len(children) > 0 {
		last := children[len(children)-1]
		// RFC3339Nano：秒级精度会让游标条目在下一页重复出现。
		nextCursor = last.CreatedAt.Format(time.RFC3339Nano) + "|" + strconv.FormatUint(uint64(last.ID), 10)
	}

	if userID, exists := c.Get("user_id"); exists {
		uid := userID.(uint)
		replyIDs := make([]uint, 0, len(children))
		for _, r := range children {
			replyIDs = append(replyIDs, r.ID)
		}
		if len(replyIDs) > 0 {
			var likedReplyIDs []uint
			h.db.Model(&models.Like{}).Where("user_id = ? AND target_type = ? AND target_id IN ?", uid, "reply", replyIDs).Pluck("target_id", &likedReplyIDs)
			likedMap := make(map[uint]bool)
			for _, id := range likedReplyIDs {
				likedMap[id] = true
			}
			for i := range children {
				if likedMap[children[i].ID] {
					children[i].IsLiked = true
				}
			}
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"replies":     children,
		"next_cursor": nextCursor,
	})
}

// CreateReplyInput 创建回复输入
type CreateReplyInput struct {
	Content        string `form:"content"`
	StickerID      string `form:"sticker_id"`
	ParentReplyID  *uint  `form:"parent_reply_id"`
	ReplyToUserID  *uint  `form:"reply_to_user_id"`
	ReplyToReplyID *uint  `form:"reply_to_reply_id"`
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

	// 如果有父回复，检查是否是一层嵌套。
	// tombstone 根（已删除但仍有正常子回复）允许继续讨论：
	// 删除只隐藏根内容，不结束整个 thread。
	var parentReply models.Reply
	if input.ParentReplyID != nil {
		if err := h.db.First(&parentReply, input.ParentReplyID).Error; err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "父回复不存在"})
			return
		} else {
			if parentReply.PostID != uint(postID) {
				c.JSON(http.StatusBadRequest, gin.H{"error": "父回复不属于当前帖子"})
				return
			}
			if parentReply.ParentReplyID != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "不支持多层嵌套"})
				return
			}
			if parentReply.Status != models.ReplyStatusNormal {
				var aliveChildren int64
				if err := h.db.Model(&models.Reply{}).
					Where("parent_reply_id = ? AND status = ?", *input.ParentReplyID, models.ReplyStatusNormal).
					Count(&aliveChildren).Error; err != nil {
					c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
					return
				}
				if aliveChildren == 0 {
					c.JSON(http.StatusBadRequest, gin.H{"error": "该评论已不可回复"})
					return
				}
			}
		}
	}

	// 通知/回复对象由服务端强制推导，客户端传值一律忽略（防止伪造通知目标）。
	// reply_to_reply_id 必须属于同一 root 线程，且目标本身必须为 normal。
	if input.ReplyToReplyID != nil {
		if input.ParentReplyID == nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "精确回复目标需要父评论"})
			return
		}
		var target models.Reply
		if err := h.db.First(&target, input.ReplyToReplyID).Error; err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "回复目标不存在"})
			return
		}
		// 目标的线程根：子回复取其 parent，根评论就是它自己。
		targetRootID := &target.ID
		if target.ParentReplyID != nil {
			targetRootID = target.ParentReplyID
		}
		if target.PostID != uint(postID) || target.Status != models.ReplyStatusNormal || *targetRootID != *input.ParentReplyID {
			c.JSON(http.StatusBadRequest, gin.H{"error": "回复目标不属于该评论线程"})
			return
		}
		uid := target.AuthorID
		input.ReplyToUserID = &uid
	} else if input.ParentReplyID != nil {
		// 未指定精确目标时回退为根评论作者（同样由服务端推导）。
		uid := parentReply.AuthorID
		input.ReplyToUserID = &uid
	} else {
		// 顶级回复不携带精确回复对象，忽略客户端伪造值。
		input.ReplyToUserID = nil
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
		PostID:         uint(postID),
		ParentReplyID:  input.ParentReplyID,
		ReplyToUserID:  input.ReplyToUserID,
		ReplyToReplyID: input.ReplyToReplyID,
		AuthorID:       userID.(uint),
		Content:        input.Content,
		StickerID:      stickerID,
		Status:         models.ReplyStatusNormal,
		CreatedAt:      time.Now(),
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
		// 回复别人的评论 → 通知被回复的评论作者。
		// 精确回复目标（reply_to_user_id）优先；缺省时回退到根评论作者。
		notifyUserID := uint(0)
		if input.ReplyToUserID != nil {
			notifyUserID = *input.ReplyToUserID
		}
		if notifyUserID == 0 {
			var parentReply models.Reply
			if err := h.db.First(&parentReply, *input.ParentReplyID).Error; err == nil {
				notifyUserID = parentReply.AuthorID
			}
		}
		if notifyUserID != 0 {
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
// 计数口径与 GetList 一致：正常回复 + tombstone 根（已删除但仍有正常子回复的根），
// 保证帖子头部的"评论 N"与评论列表实际可见条目数一致。
func recalculatePostReplyStats(tx *gorm.DB, postID uint) error {
	var post models.Post
	if err := tx.Select("id", "created_at").First(&post, postID).Error; err != nil {
		return err
	}
	var count int64
	if err := tx.Model(&models.Reply{}).Where("post_id = ? AND status = ?", postID, models.ReplyStatusNormal).Count(&count).Error; err != nil {
		return err
	}
	var tombstoneCount int64
	if err := tx.Model(&models.Reply{}).
		Where("post_id = ? AND status = ? AND parent_reply_id IS NULL AND EXISTS (SELECT 1 FROM replies c WHERE c.parent_reply_id = replies.id AND c.status = ?)",
			postID, models.ReplyStatusDeleted, models.ReplyStatusNormal).
		Count(&tombstoneCount).Error; err != nil {
		return err
	}
	count += tombstoneCount
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
		// cursor 格式: created_at|id（RFC3339Nano，保留纳秒避免游标条目重复）。
		parts := strings.Split(cursor, "|")
		if len(parts) == 2 {
			createdAt, err1 := time.Parse(time.RFC3339Nano, parts[0])
			id, err2 := strconv.ParseUint(parts[1], 10, 64)
			if err1 == nil && err2 == nil {
				whereClause += " AND (replies.created_at < ? OR (replies.created_at = ? AND replies.id < ?))"
				args = append(args, createdAt, createdAt, id)
			}
		}
	}

	var replies []models.Reply
	err := h.db.Model(&models.Reply{}).
		Select("replies.*").
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
		// RFC3339Nano：秒级精度会让游标条目在下一页重复出现。
		nextCursor = last.CreatedAt.Format(time.RFC3339Nano) + "|" + strconv.FormatUint(uint64(last.ID), 10)
	}

	// 构造返回数据，包含帖子上下文（批量 IN 查询，避免逐条 N+1）。
	type MyReplyItem struct {
		models.Reply
		PostTitle   string `json:"post_title"`
		PostContent string `json:"post_content"`
	}
	result := make([]MyReplyItem, len(replies))
	postCtx := map[uint]models.Post{}
	if len(replies) > 0 {
		postIDs := make([]uint, 0, len(replies))
		for _, r := range replies {
			postIDs = append(postIDs, r.PostID)
		}
		var posts []models.Post
		if err := h.db.Select("id", "title", "content").Where("id IN ?", postIDs).Find(&posts).Error; err == nil {
			for _, p := range posts {
				postCtx[p.ID] = p
			}
		}
	}
	for i, r := range replies {
		result[i] = MyReplyItem{
			Reply:       r,
			PostTitle:   "",
			PostContent: "",
		}
		if p, ok := postCtx[r.PostID]; ok {
			result[i].PostTitle = p.Title
			result[i].PostContent = p.Content
		} else {
			result[i].PostTitle = "[原帖已被删除]"
			result[i].PostContent = "..."
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

	// 获取关联的回复详情（批量加载回复与帖子标题，避免 N+1）
	type ReceivedReplyItem struct {
		models.Reply
		PostTitle string `json:"post_title"`
		IsRead    bool   `json:"is_read"`
	}

	relatedIDs := make([]uint, 0, len(notifications))
	for _, n := range notifications {
		relatedIDs = append(relatedIDs, n.RelatedID)
	}
	replyByID := map[uint]models.Reply{}
	if len(relatedIDs) > 0 {
		var replies []models.Reply
		if err := h.db.Preload("Author").Where("id IN ?", relatedIDs).Find(&replies).Error; err == nil {
			for _, r := range replies {
				replyByID[r.ID] = r
			}
		}
	}
	titleByID := map[uint]string{}
	if len(replyByID) > 0 {
		postIDs := make([]uint, 0, len(replyByID))
		for _, r := range replyByID {
			postIDs = append(postIDs, r.PostID)
		}
		var posts []models.Post
		if err := h.db.Select("id", "title").Where("id IN ?", postIDs).Find(&posts).Error; err == nil {
			for _, p := range posts {
				titleByID[p.ID] = p.Title
			}
		}
	}

	result := make([]ReceivedReplyItem, 0, len(notifications))
	for _, n := range notifications {
		reply, ok := replyByID[n.RelatedID]
		if !ok {
			continue
		}
		result = append(result, ReceivedReplyItem{
			Reply:     reply,
			PostTitle: titleByID[reply.PostID],
			IsRead:    n.IsRead,
		})
	}

	// 标记所有回复通知为已读
	if err := h.db.Model(&models.Notification{}).Where("user_id = ? AND type = ? AND is_read = ?", uid, "reply", false).Update("is_read", true).Error; err != nil {
		log.Printf("[DB_WARN] Failed to write side-effect record: %v", err)
	}

	c.JSON(http.StatusOK, result)
}
