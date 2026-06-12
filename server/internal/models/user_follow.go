package models

import (
	"time"
)

// UserFollow 关注关系模型
type UserFollow struct {
	ID          uint      `gorm:"primaryKey" json:"id"`
	FollowerID  uint      `gorm:"not null;uniqueIndex:idx_follow_unique" json:"follower_id"`
	FollowingID uint      `gorm:"not null;uniqueIndex:idx_follow_unique;index" json:"following_id"`
	CreatedAt   time.Time `json:"created_at"`
}
