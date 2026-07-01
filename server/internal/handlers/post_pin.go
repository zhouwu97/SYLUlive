package handlers

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

var (
	errOnlyShuitieCanPin = errors.New("only_shuitie_can_pin")
	errTooManyPinned     = errors.New("too_many_pinned")
)

type pinPostInput struct {
	PinnedUntil  string `json:"pinned_until" form:"pinned_until"`
	PinnedWeight int    `json:"pinned_weight" form:"pinned_weight"`
	Reason       string `json:"reason" form:"reason"`
}

func activePinOrder(now time.Time) clause.Expr {
	return clause.Expr{
		SQL: `CASE
			WHEN is_pinned = ? AND (pinned_until IS NULL OR pinned_until > ?)
			THEN 0 ELSE 1
		END ASC`,
		Vars: []interface{}{true, now},
	}
}

func applyPinnedOrder(query *gorm.DB, now time.Time) *gorm.DB {
	return query.
		Order(activePinOrder(now)).
		Order("pinned_weight DESC").
		Order("pinned_at DESC NULLS LAST")
}

func (h *PostHandler) AdminPinPost(c *gin.Context) {
	adminID, ok := currentUserID(c)
	if !ok {
		return
	}
	postID, ok := parseUintParam(c, "id")
	if !ok {
		return
	}

	role, _ := c.Get("role")
	isSuperAdmin := role == "super_admin"

	var input pinPostInput
	_ = c.ShouldBind(&input)

	reason := strings.TrimSpace(input.Reason)
	if reason == "" {
		reason = "管理员置顶"
	}

	weight := input.PinnedWeight
	if weight < 0 {
		weight = 0
	}
	if weight > 100 {
		weight = 100
	}

	now := time.Now()
	until, ok := parsePinnedUntil(c, strings.TrimSpace(input.PinnedUntil), now, isSuperAdmin)
	if !ok {
		return
	}

	var updatedPost models.Post
	err := h.db.Transaction(func(tx *gorm.DB) error {
		var post models.Post
		if err := tx.Clauses(lockingClause()).First(&post, postID).Error; err != nil {
			return err
		}
		if post.Status == models.PostStatusDeleted {
			return gorm.ErrRecordNotFound
		}
		if post.BoardID != models.BoardShuitie {
			return errOnlyShuitieCanPin
		}

		var activeCount int64
		if err := tx.Model(&models.Post{}).
			Where(
				"board_id = ? AND id <> ? AND status != ? AND is_pinned = ? AND (pinned_until IS NULL OR pinned_until > ?)",
				post.BoardID,
				post.ID,
				models.PostStatusDeleted,
				true,
				now,
			).
			Count(&activeCount).Error; err != nil {
			return err
		}
		if activeCount >= 3 {
			return errTooManyPinned
		}

		if err := tx.Model(&post).Updates(map[string]interface{}{
			"is_pinned":     true,
			"pinned_at":     &now,
			"pinned_until":  until,
			"pinned_by":     adminID,
			"pinned_weight": weight,
			"pinned_reason": reason,
		}).Error; err != nil {
			return err
		}

		return tx.Preload("Author").
			Preload("Images").
			Preload("Images.File").
			First(&updatedPost, post.ID).Error
	})

	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		case errors.Is(err, errOnlyShuitieCanPin):
			c.JSON(http.StatusBadRequest, gin.H{"error": "第一版仅支持首页水帖置顶"})
		case errors.Is(err, errTooManyPinned):
			c.JSON(http.StatusBadRequest, gin.H{"error": "当前板块有效置顶已达上限"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "置顶失败"})
		}
		return
	}

	responsePosts := []models.Post{updatedPost}
	h.fillLikes(c, responsePosts)
	updatedPost = responsePosts[0]
	c.JSON(http.StatusOK, updatedPost)
}

func (h *PostHandler) AdminUnpinPost(c *gin.Context) {
	postID, ok := parseUintParam(c, "id")
	if !ok {
		return
	}

	var updatedPost models.Post
	err := h.db.Transaction(func(tx *gorm.DB) error {
		var post models.Post
		if err := tx.First(&post, postID).Error; err != nil {
			return err
		}
		if post.Status == models.PostStatusDeleted {
			return gorm.ErrRecordNotFound
		}

		if err := tx.Model(&post).Updates(map[string]interface{}{
			"is_pinned":     false,
			"pinned_at":     nil,
			"pinned_until":  nil,
			"pinned_by":     0,
			"pinned_weight": 0,
			"pinned_reason": "",
		}).Error; err != nil {
			return err
		}

		return tx.Preload("Author").
			Preload("Images").
			Preload("Images.File").
			First(&updatedPost, post.ID).Error
	})
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "取消置顶失败"})
		return
	}

	responsePosts := []models.Post{updatedPost}
	h.fillLikes(c, responsePosts)
	updatedPost = responsePosts[0]
	c.JSON(http.StatusOK, updatedPost)
}

func (h *PostHandler) AdminGetPinnedPosts(c *gin.Context) {
	boardID := c.DefaultQuery("board", strconv.Itoa(int(models.BoardShuitie)))
	now := time.Now()

	query := h.db.Model(&models.Post{}).
		Where("status != ? AND is_pinned = ? AND (pinned_until IS NULL OR pinned_until > ?)",
			models.PostStatusDeleted,
			true,
			now,
		).
		Preload("Author").
		Preload("Images").
		Preload("Images.File")

	if boardID != "" {
		if id, err := strconv.Atoi(boardID); err == nil {
			query = query.Where("board_id = ?", id)
		}
	}

	var posts []models.Post
	if err := query.
		Order("pinned_weight DESC").
		Order("pinned_at DESC NULLS LAST").
		Find(&posts).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取置顶列表失败"})
		return
	}
	h.fillLikes(c, posts)
	if posts == nil {
		posts = []models.Post{}
	}
	c.JSON(http.StatusOK, posts)
}

func parsePinnedUntil(c *gin.Context, raw string, now time.Time, isSuperAdmin bool) (*time.Time, bool) {
	if raw == "" {
		defaultUntil := now.Add(3 * 24 * time.Hour)
		return &defaultUntil, true
	}

	parsed, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "置顶到期时间格式错误"})
		return nil, false
	}
	if !parsed.After(now) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "置顶到期时间必须晚于当前时间"})
		return nil, false
	}

	maxDuration := 7 * 24 * time.Hour
	if isSuperAdmin {
		maxDuration = 30 * 24 * time.Hour
	}
	if parsed.Sub(now) > maxDuration {
		c.JSON(http.StatusBadRequest, gin.H{"error": "置顶时间过长"})
		return nil, false
	}

	return &parsed, true
}
