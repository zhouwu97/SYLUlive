package models

import "time"

// FeedSnapshot 在有效期内固定候选顺序，正文与公开状态仍在每次翻页时查询。
type FeedSnapshot struct {
	SessionID        string    `gorm:"size:36;primaryKey"`
	UserID           uint      `gorm:"not null;index"`
	PostIDs          []uint    `gorm:"serializer:json;type:text"`
	ExpiredAt        time.Time `gorm:"not null;index"`
	AlgorithmVersion string
	Sort             string
	FeedKind         string
	FilterKey        string
}
