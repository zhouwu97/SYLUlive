package models

import "time"

// FeedImpression 首页 Feed 行为事件（曝光 / 打开 / 停留）。
//
// 唯一键：user_id + feed_session_id + feed_kind + post_id。
// 同一用户同一 FeedSession 内同一帖子只保留一行，事件通过幂等 upsert 聚合：
//   - impression：visible_ms 取最大（upsert）；
//   - open：opened_at 取最早非空值；
//   - dwell：dwell_ms 取最大，禁止累加（防止重试翻倍）。
//
// FeedSessionID 是分析事件专用 session（见 FEED-2），
// 与现有 Snapshot 的 session_id（10 分钟分页快照）是不同概念，不要混用。
type FeedImpression struct {
	ID uint `gorm:"primaryKey" json:"id"`

	UserID        uint   `gorm:"not null;uniqueIndex:idx_feed_impression_unique" json:"user_id"`
	PostID        uint   `gorm:"not null;uniqueIndex:idx_feed_impression_unique" json:"post_id"`
	FeedSessionID string `gorm:"not null;uniqueIndex:idx_feed_impression_unique;size:64" json:"feed_session_id"`
	FeedKind      string `gorm:"not null;uniqueIndex:idx_feed_impression_unique;size:16" json:"feed_kind"`

	Position         int    `gorm:"not null;default:0" json:"position"`
	AlgorithmVersion string `gorm:"size:32" json:"algorithm_version"`

	VisibleMS int        `gorm:"not null;default:0" json:"visible_ms"`
	OpenedAt  *time.Time `json:"opened_at"`
	DwellMS   int        `gorm:"not null;default:0" json:"dwell_ms"`

	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// FeedEventType Feed 行为事件类型。
type FeedEventType string

const (
	FeedEventImpression FeedEventType = "impression"
	FeedEventOpen       FeedEventType = "open"
	FeedEventDwell      FeedEventType = "dwell"
)

// FeedKind Feed Tab 标识（FEED-0 语义：综合/最新/精华/关注）。
var FeedKinds = []string{"all", "time", "featured", "following"}

// IsValidFeedKind 校验 feed_kind 是否合法。
func IsValidFeedKind(kind string) bool {
	for _, k := range FeedKinds {
		if k == kind {
			return true
		}
	}
	return false
}
