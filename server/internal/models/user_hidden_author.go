package models

import "time"

// UserHiddenAuthor 用户级 Feed Filter：隐藏该作者（不看TA）。
// 与 UserFollow 无关：隐藏不取消关注，恢复隐藏后作者自然重新出现在关注流。
// HideFromFeed != BlockUser：仅影响 Feed 列表（综合/最新/精华/关注），
// 不影响搜索、主页、直接帖子 URL、评论区与私信。
type UserHiddenAuthor struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	UserID    uint      `gorm:"not null;uniqueIndex:idx_hidden_author_unique" json:"user_id"`
	AuthorID  uint      `gorm:"not null;uniqueIndex:idx_hidden_author_unique" json:"author_id"`
	CreatedAt time.Time `json:"created_at"`
}
