package models

import "time"

// FeedRankTrace 个性化排序追踪（FEED-5 §30）。
// 只采样（约 5% 请求），用于解释与调参；保留 30 天。
type FeedRankTrace struct {
	ID uint `gorm:"primaryKey" json:"id"`

	UserID     uint   `gorm:"index:idx_feed_rank_trace_user;not null" json:"user_id"`
	SnapshotID string `gorm:"size:64;index:idx_feed_rank_trace_user,priority:2" json:"snapshot_id"`
	PostID     uint   `gorm:"not null" json:"post_id"`
	Position   int    `gorm:"not null;default:0" json:"position"`

	HotScore      float64 `json:"hot_score"`
	ActivityScore float64 `json:"activity_score"`

	AuthorAffinity  float64 `json:"author_affinity"`
	SectionAffinity float64 `json:"section_affinity"`
	FollowSignal    float64 `json:"follow_signal"`
	SeenPenalty     float64 `json:"seen_penalty"`
	PersonalDelta   float64 `json:"personal_delta"`
	FinalScore      float64 `json:"final_adjusted_score"`

	ReasonCodes      string `gorm:"size:128" json:"reason_codes"`
	AlgorithmVersion string `gorm:"size:32" json:"algorithm_version"`

	CreatedAt time.Time `json:"created_at"`
}
