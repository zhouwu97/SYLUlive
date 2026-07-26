package models

import (
	"time"

	"gorm.io/datatypes"
)

// UserDevice 是可执行只读本地工具的已登记安装实例。
// installation_id 只标识一次 App 安装，不是用户身份；每次设备接口仍须校验 JWT 用户。
type UserDevice struct {
	ID                    string         `gorm:"type:varchar(36);primaryKey" json:"id"`
	UserID                uint           `gorm:"not null;index:idx_user_devices_user_seen,priority:1" json:"-"`
	InstallationID        string         `gorm:"size:128;not null;uniqueIndex" json:"installation_id"`
	PushToken             string         `gorm:"size:255;not null;default:''" json:"-"`
	ToolNames             datatypes.JSON `gorm:"type:jsonb;not null" json:"tool_names"`
	BridgeProtocolVersion int            `gorm:"not null;default:1" json:"bridge_protocol_version"`
	ClientVersion         string         `gorm:"size:32;not null;default:''" json:"client_version"`
	LastSeenAt            time.Time      `gorm:"not null;index:idx_user_devices_user_seen,priority:2" json:"last_seen_at"`
	RevokedAt             *time.Time     `gorm:"index" json:"revoked_at,omitempty"`
	CreatedAt             time.Time      `json:"created_at"`
	UpdatedAt             time.Time      `json:"updated_at"`
}

func (UserDevice) TableName() string { return "user_devices" }
