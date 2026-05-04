package models

import "time"

// AnnouncementRead 用户已读公告记录
type AnnouncementRead struct {
	ID             uint      `gorm:"primaryKey" json:"id"`
	UserID         uint      `gorm:"uniqueIndex:idx_user_announcement;not null" json:"user_id"`
	AnnouncementID uint      `gorm:"uniqueIndex:idx_user_announcement;not null" json:"announcement_id"`
	ReadAt         time.Time `json:"read_at"`
}
