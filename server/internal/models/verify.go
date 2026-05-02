package models

import "time"

// VerifyCode 邮箱验证码
type VerifyCode struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	QQ        string    `gorm:"uniqueIndex;size:20;not null" json:"qq"`
	Code      string    `gorm:"size:10;not null" json:"code"`
	ExpiresAt time.Time `json:"expires_at"`
	CreatedAt time.Time `json:"created_at"`
}
