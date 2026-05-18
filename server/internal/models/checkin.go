package models

import (
	"time"
)

// CheckIn 签到记录模型
type CheckIn struct {
	ID          uint      `gorm:"primaryKey" json:"id"`
	UserID      uint      `gorm:"not null;index" json:"user_id"`
	CheckInDate string    `gorm:"size:10;not null;index" json:"check_in_date"` // 格式: 2026-05-12
	StreakDays   int       `gorm:"default:1" json:"streak_days"`               // 连续签到天数
	ExpEarned   int       `gorm:"default:1" json:"exp_earned"`                 // 本次获得经验
	CreatedAt   time.Time `json:"created_at"`
}
