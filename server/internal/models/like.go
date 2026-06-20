package models

import (
	"time"
)

// Like 点赞模型
type Like struct {
	ID         uint      `gorm:"primaryKey" json:"id"`
	UserID     uint      `gorm:"not null;uniqueIndex:idx_like_unique" json:"user_id"`
	TargetType string    `gorm:"size:20;not null;uniqueIndex:idx_like_unique" json:"target_type"` // post/reply
	TargetID   uint      `gorm:"not null;uniqueIndex:idx_like_unique" json:"target_id"`
	CreatedAt  time.Time `json:"created_at"`
}

// UniqueLikes 联合唯一索引，防止重复点赞
func (Like) TableName() string {
	return "likes"
}
