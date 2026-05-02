package models

import "time"

// Tutorial 教程内容（管理员可编辑的图文页面）
type Tutorial struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	PageKey   string    `gorm:"uniqueIndex;size:50;not null" json:"page_key"` // 页面标识，如 "exam_extract"
	Title     string    `gorm:"size:200;not null" json:"title"`               // 页面标题
	Content   string    `gorm:"type:text;not null" json:"content"`            // Markdown 内容
	UpdatedBy uint      `gorm:"not null" json:"updated_by"`
	Updater   User      `gorm:"foreignKey:UpdatedBy" json:"updater"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}
