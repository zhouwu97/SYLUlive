package models

import "time"

// FeedFeedback 用户对 Feed 单帖的显式负反馈。
// Source 记录用户点击反馈时所在的 Feed Tab，仅用于分析，不代表只在该 Tab 生效。
type FeedFeedback struct {
	ID        uint       `gorm:"primaryKey" json:"id"`
	UserID    uint       `gorm:"not null;uniqueIndex:idx_feed_feedback_unique" json:"user_id"`
	PostID    uint       `gorm:"not null;uniqueIndex:idx_feed_feedback_unique" json:"post_id"`
	Action    string     `gorm:"not null;uniqueIndex:idx_feed_feedback_unique;size:32" json:"action"`
	Source    string     `gorm:"not null;size:16;default:all" json:"source"`
	CreatedAt time.Time  `json:"created_at"`
	ExpiresAt *time.Time `json:"expires_at"`
}

const (
	// FeedFeedbackActionNotInterested 不感兴趣（P0 唯一 action）
	FeedFeedbackActionNotInterested = "not_interested"
)

// FeedFeedbackSources 允许的 Source 值：用户点击时所在的 Feed Tab。
var FeedFeedbackSources = []string{"all", "time", "featured", "following"}

// IsValidFeedFeedbackSource 校验 Source 是否合法。
func IsValidFeedFeedbackSource(source string) bool {
	for _, s := range FeedFeedbackSources {
		if s == source {
			return true
		}
	}
	return false
}
