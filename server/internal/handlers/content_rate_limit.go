package handlers

import (
	"time"

	"shenliyuan/internal/models"
)

// postRateLimited 使用持久化计数，避免仅依赖单进程内存导致重启或多实例绕过。
func (h *PostHandler) postRateLimited(userID uint) bool {
	now := time.Now()
	var recent, daily int64
	h.db.Model(&models.Post{}).Where("author_id = ? AND created_at >= ?", userID, now.Add(-5*time.Minute)).Count(&recent)
	h.db.Model(&models.Post{}).Where("author_id = ? AND created_at >= ?", userID, now.Add(-24*time.Hour)).Count(&daily)
	return recent >= 6 || daily >= 30
}

func (h *ReplyHandler) replyRateLimited(userID, postID uint, content string) bool {
	now := time.Now()
	var recent, daily, duplicate int64
	h.db.Model(&models.Reply{}).Where("author_id = ? AND created_at >= ?", userID, now.Add(-10*time.Minute)).Count(&recent)
	h.db.Model(&models.Reply{}).Where("author_id = ? AND created_at >= ?", userID, now.Add(-24*time.Hour)).Count(&daily)
	if content != "" {
		h.db.Model(&models.Reply{}).Where("author_id = ? AND post_id = ? AND content = ? AND created_at >= ?", userID, postID, content, now.Add(-time.Minute)).Count(&duplicate)
	}
	return recent >= 30 || daily >= 200 || duplicate > 0
}
