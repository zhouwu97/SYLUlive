package models

import (
	"time"
)

// Announcement 公告
type Announcement struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	Title     string    `gorm:"size:200;not null" json:"title"`
	Content   string    `gorm:"type:text;not null" json:"content"`
	IsPinned  bool      `gorm:"default:false" json:"is_pinned"`
	CreatedBy uint      `gorm:"not null" json:"created_by"`
	Creator   User      `gorm:"foreignKey:CreatedBy" json:"creator"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}