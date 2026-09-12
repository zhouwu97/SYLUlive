package models

import "time"

// RefreshToken 保存可轮换的长期会话凭据，仅保存摘要，原文只存在客户端。
type RefreshToken struct {
	ID            uint       `gorm:"primaryKey" json:"id"`
	UserID        uint       `gorm:"not null;index" json:"user_id"`
	TokenVersion  int        `gorm:"not null;default:0" json:"-"`
	TokenHash     string     `gorm:"size:64;not null;uniqueIndex" json:"-"`
	TokenFamily   string     `gorm:"size:64;not null;index" json:"-"`
	ExpiresAt     time.Time  `gorm:"not null;index" json:"expires_at"`
	LastUsedAt    *time.Time `json:"-"`
	RevokedAt     *time.Time `gorm:"index" json:"-"`
	ReplacedBy    *uint      `gorm:"column:replaced_by;index" json:"-"`
	CreatedIPHash string     `gorm:"size:64" json:"-"`
	UserAgentHash string     `gorm:"size:64" json:"-"`
	CreatedAt     time.Time  `json:"created_at"`
}
