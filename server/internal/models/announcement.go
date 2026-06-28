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

	// Status: draft / published / archived
	Status string `gorm:"size:20;not null;default:'published';index" json:"status"`
	// DisplayMode: center / banner / modal
	DisplayMode string `gorm:"size:20;not null;default:'center'" json:"display_mode"`
	// Priority: normal / important / urgent
	Priority string `gorm:"size:20;not null;default:'normal'" json:"priority"`
	// PublishAt: delayed publish, nil = immediately visible
	PublishAt *time.Time `json:"publish_at"`
	// ExpiresAt: auto-expiry, nil = never expires
	ExpiresAt *time.Time `gorm:"index" json:"expires_at"`
	// IncludeNewUsers: if true, visible to users who registered after this announcement was created
	IncludeNewUsers bool `gorm:"not null;default:false" json:"include_new_users"`

	CreatedBy uint      `gorm:"not null" json:"created_by"`
	Creator   User      `gorm:"foreignKey:CreatedBy" json:"creator"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}
