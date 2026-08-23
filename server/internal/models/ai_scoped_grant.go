package models

import (
	"time"

	"gorm.io/datatypes"
)

// AIScopedGrant 是跨 Go 实例共享的短期 MCP Grant。
// 数据库存 token 摘要，不保存可直接复用的明文 token。
type AIScopedGrant struct {
	TokenHash         string         `gorm:"size:64;primaryKey" json:"-"`
	RunID             string         `gorm:"type:varchar(36);not null;index" json:"run_id"`
	UserID            uint           `gorm:"not null;index" json:"user_id"`
	AllowedJSON       datatypes.JSON `gorm:"type:jsonb;not null" json:"-"`
	ScopesJSON        datatypes.JSON `gorm:"type:jsonb;not null" json:"-"`
	PermissionScope   string         `gorm:"size:48;not null;default:''" json:"-"`
	PermissionVersion int64          `gorm:"not null;default:0" json:"-"`
	Status            string         `gorm:"size:16;not null;index" json:"status"`
	ExpiresAt         time.Time      `gorm:"not null;index" json:"expires_at"`
	MaxCalls          int            `gorm:"not null" json:"max_calls"`
	Calls             int            `gorm:"not null;default:0" json:"calls"`
	CreatedAt         time.Time      `json:"created_at"`
	UpdatedAt         time.Time      `json:"updated_at"`
}

func (AIScopedGrant) TableName() string { return "ai_scoped_grants" }
