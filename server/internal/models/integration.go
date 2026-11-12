package models

import (
	"gorm.io/datatypes"
	"time"
)

// 集成凭证不属于 App 登录会话；模型工具与 JSON 响应不得接触其摘要或安全快照。
type IntegrationDeviceRequest struct {
	ID               string    `gorm:"size:36;primaryKey"`
	DeviceHash       string    `gorm:"size:64;uniqueIndex;not null" json:"-"`
	UserCodeHash     string    `gorm:"size:64;uniqueIndex;not null" json:"-"`
	InstallationID   string    `gorm:"size:36;not null"`
	InstallationName string    `gorm:"size:80;not null"`
	RequestedScopes  string    `gorm:"size:512;not null"`
	OwnerID          uint      `gorm:"index"`
	NonceHash        string    `gorm:"size:64" json:"-"`
	BindingID        string    `gorm:"size:36"`
	State            string    `gorm:"size:20;not null;index"`
	ExpiresAt        time.Time `gorm:"index;not null"`
	NextPollAt       time.Time
	PollInterval     int `gorm:"not null;default:5"`
	CreatedAt        time.Time
}

type IntegrationBinding struct {
	ID                string     `gorm:"size:36;primaryKey" json:"binding_id"`
	OwnerID           uint       `gorm:"not null;uniqueIndex:ux_integration_owner_active,where:state = 'active'" json:"-"`
	InstallationID    string     `gorm:"size:36;not null;uniqueIndex:ux_integration_install_active,where:state = 'active'" json:"installation_id"`
	InstallationName  string     `gorm:"size:80;not null" json:"installation_name"`
	State             string     `gorm:"size:20;not null;index" json:"state"`
	Scopes            string     `gorm:"size:512;not null" json:"scopes"`
	Epoch             uint       `gorm:"not null;default:1" json:"epoch"`
	AcademicBindingID uint       `gorm:"not null" json:"-"`
	AcademicVersion   uint       `gorm:"not null" json:"-"`
	TokenVersion      int        `gorm:"not null" json:"-"`
	CreatedAt         time.Time  `json:"created_at"`
	RevokedAt         *time.Time `json:"revoked_at,omitempty"`
}

type IntegrationCredential struct {
	ID                 string     `gorm:"size:36;primaryKey" json:"-"`
	BindingID          string     `gorm:"size:36;not null;index" json:"-"`
	TokenHash          string     `gorm:"size:64;not null;uniqueIndex" json:"-"`
	Kind               string     `gorm:"size:10;not null" json:"-"`
	Epoch              uint       `gorm:"not null" json:"-"`
	UsedAt             *time.Time `json:"-"`
	RefreshRequestHash string     `gorm:"size:64;not null;default:''" json:"-"`
	ExpiresAt          time.Time  `gorm:"index;not null" json:"-"`
	AbsoluteExpiresAt  time.Time  `json:"-"`
	CreatedAt          time.Time  `json:"-"`
}

// ManagedBot 无登录凭据/教务身份；一个创建者至多一个，公开时仅展示独立机器人身份。
type ManagedBot struct {
	OwnerID     uint      `gorm:"primaryKey" json:"-"`
	UserID      uint      `gorm:"not null;uniqueIndex" json:"bot_user_id"`
	Enabled     bool      `gorm:"not null;default:false" json:"enabled"`
	PolicyJSON  string    `gorm:"type:text;not null;default:''" json:"-"`
	Revision    uint64    `gorm:"not null;default:1" json:"revision"`
	RuntimeJSON string    `gorm:"type:text;not null;default:''" json:"-"`
	CreatedAt   time.Time `json:"created_at"`
}

// ManagedBotPolicy 是创建者授予机器人的社区权限上限，不能覆盖平台治理或连接 scope。
type ManagedBotPolicy struct {
	PublicReadEnabled       bool     `json:"public_read_enabled"`
	ReplyEnabled            bool     `json:"reply_enabled"`
	PostEnabled             bool     `json:"post_enabled"`
	ImageEnabled            bool     `json:"image_enabled"`
	StickerEnabled          bool     `json:"sticker_enabled"`
	AllowedPostTypes        []string `json:"allowed_post_types"`
	BlockedTerms            []string `json:"blocked_terms"`
	BlockLinks              bool     `json:"block_links"`
	DailyReplyLimit         int      `json:"daily_reply_limit"`
	MinReplyIntervalMinutes int      `json:"min_reply_interval_minutes"`
}

type IntegrationAction struct {
	ID               string         `gorm:"size:36;primaryKey" json:"action_id"`
	BindingID        string         `gorm:"size:36;not null;index;uniqueIndex:ux_integration_operation,priority:1" json:"-"`
	OwnerID          uint           `gorm:"not null;index" json:"-"`
	OperationID      string         `gorm:"size:36;not null;uniqueIndex:ux_integration_operation,priority:2" json:"-"`
	RequestHash      string         `gorm:"size:64;not null" json:"-"`
	BindingEpoch     uint           `gorm:"not null" json:"-"`
	Kind             string         `gorm:"size:16;not null" json:"kind"`
	State            string         `gorm:"size:20;not null;index" json:"state"`
	Version          uint           `gorm:"not null;default:1" json:"draft_version"`
	Payload          datatypes.JSON `gorm:"type:jsonb;not null" json:"payload"`
	PayloadHash      string         `gorm:"size:64;not null" json:"payload_hash"`
	ConfirmNonceHash string         `gorm:"size:64" json:"-"`
	ConfirmExpiresAt *time.Time     `json:"-"`
	PostID           *uint          `json:"post_id,omitempty"`
	ReplyID          *uint          `json:"reply_id,omitempty"`
	CreatedAt        time.Time      `json:"created_at"`
	ExpiresAt        time.Time      `gorm:"index;not null" json:"expires_at"`
	CompletedAt      *time.Time     `json:"completed_at,omitempty"`
}

type IntegrationAudit struct {
	ID        uint64    `gorm:"primaryKey"`
	OwnerID   uint      `gorm:"index;not null"`
	BindingID string    `gorm:"size:36;index"`
	ActionID  string    `gorm:"size:36"`
	Event     string    `gorm:"size:40;not null"`
	ActorID   uint      `gorm:"index"`
	Reason    string    `gorm:"size:240"`
	CreatedAt time.Time `gorm:"index"`
}
