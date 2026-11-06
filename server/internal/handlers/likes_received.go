package handlers

import (
	"net/http"
	"strconv"
	"time"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
)

// GetReceivedLikes 只展示当前用户仍可访问的帖子、评论所收到的赞。
// 直接查询点赞表也能覆盖旧版本的历史记录，取消点赞后自然从列表移除。
func (h *LikeHandler) GetReceivedLikes(c *gin.Context) {
	uid := c.MustGet("user_id").(uint)
	limit := 30
	if raw := c.Query("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed <= 0 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "limit必须是正整数"})
			return
		}
		limit = min(parsed, 50)
	}
	var cursor uint64
	if raw := c.Query("cursor"); raw != "" {
		parsed, err := strconv.ParseUint(raw, 10, 64)
		if err != nil || parsed == 0 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "点赞游标无效"})
			return
		}
		cursor = parsed
	}
	type item struct {
		ID         uint      `json:"id"`
		UserID     uint      `json:"user_id"`
		Nickname   string    `json:"nickname"`
		Avatar     string    `json:"avatar"`
		TargetType string    `json:"target_type"`
		TargetID   uint      `json:"target_id"`
		PostID     uint      `json:"post_id"`
		PostTitle  string    `json:"post_title"`
		CreatedAt  time.Time `json:"created_at"`
	}
	items := make([]item, 0)
	query := models.EffectiveReceivedLikes(h.db.WithContext(c.Request.Context()), []uint{uid}).
		Select("l.id, l.user_id, u.nickname, u.avatar, l.target_type, l.target_id, l.post_id, l.post_title, l.created_at")
	if cursor > 0 {
		query = query.Where("l.id < ?", cursor)
	}
	if err := query.Order("l.id DESC").Limit(limit + 1).Scan(&items).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取收到的赞失败"})
		return
	}
	hasMore := len(items) > limit
	nextCursor := ""
	if hasMore {
		items = items[:limit]
		nextCursor = strconv.FormatUint(uint64(items[len(items)-1].ID), 10)
	}
	c.JSON(http.StatusOK, gin.H{"items": items, "has_more": hasMore, "next_cursor": nextCursor})
}
