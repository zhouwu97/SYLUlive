package handlers

import (
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// hiddenAuthorRow 隐藏作者列表返回项。
type hiddenAuthorRow struct {
	AuthorID uint      `json:"author_id"`
	Nickname string    `json:"nickname"`
	Avatar   string    `json:"avatar"`
	HiddenAt time.Time `json:"hidden_at"`
}

// FeedHandler 处理 /api/feed 下推荐相关的用户控制接口（FEED-1）。
type FeedHandler struct {
	db         *gorm.DB
	visibility *services.FeedVisibilityService
}

func NewFeedHandler(db *gorm.DB) *FeedHandler {
	return &FeedHandler{db: db, visibility: services.NewFeedVisibilityService(db)}
}

func requireFeedUser(c *gin.Context) (uint, bool) {
	rawUserID, exists := c.Get("user_id")
	userID, ok := rawUserID.(uint)
	if !exists || !ok || userID == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录", "code": "authentication_required"})
		return 0, false
	}
	return userID, true
}

// optionalFeedUserID 返回当前用户 ID；未登录或类型异常时为 0。
// 用于可选鉴权的 Feed 查询（未登录时不应用负反馈过滤）。
func optionalFeedUserID(c *gin.Context) uint {
	raw, _ := c.Get("user_id")
	if v, ok := raw.(uint); ok {
		return v
	}
	return 0
}

// MarkNotInterested  PUT /api/feed/posts/:post_id/not-interested
//
//	query: source=all|time|featured|following（用户点击时所在 Tab，仅用于分析，默认 all）
func (h *FeedHandler) MarkNotInterested(c *gin.Context) {
	userID, ok := requireFeedUser(c)
	if !ok {
		return
	}
	postID, ok := parseFeedPostID(c)
	if !ok {
		return
	}
	source := c.DefaultQuery("source", "all")
	if !models.IsValidFeedFeedbackSource(source) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的 source"})
		return
	}
	var post models.Post
	if err := h.db.Select("id", "status", "author_id").First(&post, postID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}
	// H1.3：不允许对自己的帖子标记不感兴趣。
	if post.AuthorID == userID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不能对自己的帖子标记不感兴趣"})
		return
	}
	if err := h.visibility.MarkNotInterested(userID, postID, source); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	invalidateUserFeedSnapshots(userID)
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// UndoNotInterested  DELETE /api/feed/posts/:post_id/not-interested
func (h *FeedHandler) UndoNotInterested(c *gin.Context) {
	userID, ok := requireFeedUser(c)
	if !ok {
		return
	}
	postID, ok := parseFeedPostID(c)
	if !ok {
		return
	}
	if err := h.visibility.UndoNotInterested(userID, postID); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	invalidateUserFeedSnapshots(userID)
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// HideAuthor  PUT /api/feed/authors/:author_id/hidden
//
// 不看TA：Feed 级过滤，不取消关注。
func (h *FeedHandler) HideAuthor(c *gin.Context) {
	userID, ok := requireFeedUser(c)
	if !ok {
		return
	}
	authorID, ok := parseFeedAuthorID(c)
	if !ok {
		return
	}
	var author models.User
	if err := h.db.Select("id").First(&author, authorID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "作者不存在"})
		return
	}
	// H1.3：不允许隐藏自己。
	if authorID == userID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不能隐藏自己"})
		return
	}
	if err := h.visibility.HideAuthor(userID, authorID); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	invalidateUserFeedSnapshots(userID)
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// RestoreAuthor  DELETE /api/feed/authors/:author_id/hidden
func (h *FeedHandler) RestoreAuthor(c *gin.Context) {
	userID, ok := requireFeedUser(c)
	if !ok {
		return
	}
	authorID, ok := parseFeedAuthorID(c)
	if !ok {
		return
	}
	if err := h.visibility.RestoreAuthor(userID, authorID); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	invalidateUserFeedSnapshots(userID)
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// GetHiddenAuthors  GET /api/feed/hidden-authors
//
// 返回用户隐藏的作者列表（含作者信息，按隐藏时间倒序）。
func (h *FeedHandler) GetHiddenAuthors(c *gin.Context) {
	userID, ok := requireFeedUser(c)
	if !ok {
		return
	}
	var rows []hiddenAuthorRow
	err := h.db.Table("user_hidden_authors uha").
		Select("uha.author_id, u.nickname, u.avatar, uha.created_at AS hidden_at").
		Joins("JOIN users u ON u.id = uha.author_id").
		Where("uha.user_id = ?", userID).
		Order("uha.created_at DESC").
		Scan(&rows).Error
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	if rows == nil {
		rows = []hiddenAuthorRow{}
	}
	c.JSON(http.StatusOK, gin.H{"authors": rows})
}

func parseFeedPostID(c *gin.Context) (uint, bool) {
	postID, err := strconv.ParseUint(c.Param("post_id"), 10, 64)
	if err != nil || postID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return 0, false
	}
	return uint(postID), true
}

func parseFeedAuthorID(c *gin.Context) (uint, bool) {
	authorID, err := strconv.ParseUint(c.Param("author_id"), 10, 64)
	if err != nil || authorID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的作者ID"})
		return 0, false
	}
	return uint(authorID), true
}
