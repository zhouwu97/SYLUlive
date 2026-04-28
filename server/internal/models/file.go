package models

import (
	"time"
)

// File 文件模型（SHA256哈希去重）
type File struct {
	ID       uint      `gorm:"primaryKey" json:"id"`
	Hash     string    `gorm:"uniqueIndex;size:64;not null" json:"hash"` // SHA256哈希
	Path     string    `gorm:"size:500;not null" json:"path"`
	Size     int64     `gorm:"not null" json:"size"`
	MimeType string    `gorm:"size:100;not null" json:"mime_type"`
	RefCount int       `gorm:"default:1" json:"ref_count"` // 引用计数
	CreatedAt time.Time `json:"created_at"`
}