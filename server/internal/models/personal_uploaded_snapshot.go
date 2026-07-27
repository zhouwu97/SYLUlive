package models

import (
	"time"

	"gorm.io/datatypes"
)

// PersonalUploadedSnapshot 保存用户明确同意上传的结构化个人数据。
// 该表不保存密码、Cookie、设备密钥、会话或原始页面内容。
type PersonalUploadedSnapshot struct {
	ID            uint           `gorm:"primaryKey" json:"id"`
	UserID        uint           `gorm:"not null;uniqueIndex:idx_personal_uploaded_snapshots_user_type,priority:1;index" json:"-"`
	SnapshotType  string         `gorm:"size:48;not null;uniqueIndex:idx_personal_uploaded_snapshots_user_type,priority:2;index" json:"snapshot_type"`
	SchemaVersion int            `gorm:"not null" json:"schema_version"`
	PayloadJSON   datatypes.JSON `gorm:"type:jsonb;not null" json:"-"`
	PayloadHash   string         `gorm:"size:64;not null" json:"payload_hash"`
	FetchedAt     time.Time      `gorm:"not null;index" json:"fetched_at"`
	ExpiresAt     time.Time      `gorm:"not null;index" json:"expires_at"`
	IsPartial     bool           `gorm:"not null;default:false" json:"is_partial"`
	CreatedAt     time.Time      `json:"created_at"`
	UpdatedAt     time.Time      `json:"updated_at"`
}

func (PersonalUploadedSnapshot) TableName() string { return "personal_uploaded_snapshots" }
