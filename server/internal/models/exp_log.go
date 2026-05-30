package models

import (
	"time"
)

// ExpLog 记录用户获取每日经验的日志，防止并发重复获取
type ExpLog struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	UserID    uint      `gorm:"not null;uniqueIndex:idx_user_action_date" json:"user_id"`
	Action    string    `gorm:"size:50;not null;uniqueIndex:idx_user_action_date" json:"action"` // "post_daily", "reply_daily"
	Date      time.Time `gorm:"type:date;not null;uniqueIndex:idx_user_action_date" json:"date"`
	ExpEarned int       `json:"exp_earned"`
	CreatedAt time.Time `json:"created_at"`
}
