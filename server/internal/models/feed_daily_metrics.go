package models

import "time"

// FeedDailyMetrics 按日聚合的 Feed 指标（FEED-4）。
// 长期保留；原始明细 feed_impressions 只保留 30 天（TTL）。
//
// 唯一键：date + feed_kind + algorithm_version。
// 同一天重复聚合必须幂等（upsert，数值取聚合结果而非累加）。
type FeedDailyMetrics struct {
	ID uint `gorm:"primaryKey" json:"id"`

	Date             time.Time `gorm:"not null;uniqueIndex:idx_feed_daily_metrics" json:"date"` // 仅日期（YYYY-MM-DD）
	FeedKind         string    `gorm:"not null;uniqueIndex:idx_feed_daily_metrics;size:16" json:"feed_kind"`
	AlgorithmVersion string    `gorm:"not null;uniqueIndex:idx_feed_daily_metrics;size:32" json:"algorithm_version"`

	// 曝光
	Impressions  int   `gorm:"not null;default:0" json:"impressions"`
	UniqueOpens  int   `gorm:"not null;default:0" json:"unique_opens"`
	SumDwellMS   int64 `gorm:"not null;default:0" json:"sum_dwell_ms"`
	SumVisibleMS int64 `gorm:"not null;default:0" json:"sum_visible_ms"`

	// 负反馈
	NotInterested int `gorm:"not null;default:0" json:"not_interested"`
	HiddenAuthors int `gorm:"not null;default:0" json:"hidden_authors"`

	// 互动
	Likes     int `gorm:"not null;default:0" json:"likes"`
	Replies   int `gorm:"not null;default:0" json:"replies"`
	PollVotes int `gorm:"not null;default:0" json:"poll_votes"`

	// FEED-V5：post_like / reply_like 分开统计，避免揉成一个数字，
	// 便于判断 V5 是否真正提高"深层互动"。
	PostLikes  int `gorm:"not null;default:0" json:"post_likes"`
	ReplyLikes int `gorm:"not null;default:0" json:"reply_likes"`

	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}
