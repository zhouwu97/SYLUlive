package models

import (
	"time"

	"gorm.io/datatypes"
)

// AcademicSnapshot 保存服务端可授权读取的最小学业快照。
// 二课密码、Cookie、设备密钥和原始页面内容不得写入此表。
type AcademicSnapshot struct {
	ID                   uint           `gorm:"primaryKey" json:"id"`
	UserID               uint           `gorm:"not null;uniqueIndex:idx_academic_snapshots_user_dataset_scope,priority:1;index" json:"-"`
	DatasetType          string         `gorm:"size:48;not null;uniqueIndex:idx_academic_snapshots_user_dataset_scope,priority:2;index" json:"dataset_type"`
	ScopeKey             string         `gorm:"size:96;not null;default:'';uniqueIndex:idx_academic_snapshots_user_dataset_scope,priority:3" json:"scope_key"`
	SchemaVersion        int            `gorm:"not null;default:1" json:"schema_version"`
	Source               string         `gorm:"size:48;not null" json:"source"`
	PayloadJSON          datatypes.JSON `gorm:"not null" json:"-"`
	PayloadHash          string         `gorm:"size:64;not null" json:"-"`
	FetchedAt            time.Time      `gorm:"not null;index" json:"fetched_at"`
	ExpiresAt            time.Time      `gorm:"not null;index" json:"expires_at"`
	IsPartial            bool           `gorm:"not null;default:false" json:"is_partial"`
	CredentialGeneration uint           `gorm:"not null;default:0;index" json:"-"`
	CreatedAt            time.Time      `json:"created_at"`
	UpdatedAt            time.Time      `json:"updated_at"`
}

func (AcademicSnapshot) TableName() string { return "academic_snapshots" }
