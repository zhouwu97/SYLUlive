package models

import (
	"time"
)

// FileAccessScope 描述文件的访问范围，与 Status 生命周期字段相互独立。
type FileAccessScope string

const (
	FileAccessPrivate FileAccessScope = "private"
	FileAccessPublic  FileAccessScope = "public"
)

// File 文件模型（SHA256哈希去重）
type File struct {
	ID          uint            `gorm:"primaryKey" json:"id"`
	Hash        string          `gorm:"uniqueIndex;size:64;not null" json:"hash"` // SHA256哈希
	Path        string          `gorm:"size:500;not null" json:"path"`
	Size        int64           `gorm:"not null" json:"size"`
	MimeType    string          `gorm:"size:100;not null" json:"mime_type"`
	UploaderID  uint            `gorm:"index;not null;default:0" json:"-"`
	Status      string          `gorm:"size:20;not null;default:'temporary';index" json:"status"`
	AccessScope FileAccessScope `gorm:"size:16;not null;default:'private';index" json:"-"`
	ClaimedAt   *time.Time      `json:"claimed_at"`
	RefCount    int             `gorm:"default:1" json:"ref_count"` // 引用计数
	CreatedAt   time.Time       `json:"created_at"`
}

// FileUploadGrant 记录用户通过上传接口取得的文件引用权，兼容全局哈希去重。
type FileUploadGrant struct {
	ID        uint      `gorm:"primaryKey" json:"-"`
	FileID    uint      `gorm:"not null;uniqueIndex:idx_file_upload_grant" json:"-"`
	UserID    uint      `gorm:"not null;uniqueIndex:idx_file_upload_grant" json:"-"`
	CreatedAt time.Time `json:"-"`
}
