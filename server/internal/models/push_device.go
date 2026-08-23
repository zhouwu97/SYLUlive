package models

import "time"

// PushDevice 表示一个用户在一个 App 安装上的远程推送绑定。
//
// 同一用户可以同时拥有 Android、iOS 和 OHOS 多条记录；DeviceID 仍按安装
// 维度唯一，换账号时会转移该安装的归属，避免推送串号。
type PushDevice struct {
	ID             uint      `gorm:"primaryKey" json:"id"`
	UserID         uint      `gorm:"not null;index:idx_push_devices_user_enabled,priority:1" json:"user_id"`
	DeviceID       string    `gorm:"size:128;not null;uniqueIndex:idx_push_devices_device_id" json:"device_id"`
	Platform       string    `gorm:"size:16;not null;index:idx_push_devices_user_enabled,priority:2" json:"platform"`
	PushProvider   string    `gorm:"size:32;not null;default:'jpush'" json:"push_provider"`
	RegistrationID string    `gorm:"size:255;not null" json:"-"`
	Enabled        bool      `gorm:"not null;default:false;index:idx_push_devices_user_enabled,priority:3" json:"enabled"`
	LastSeenAt     time.Time `gorm:"not null;index" json:"last_seen_at"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

func (PushDevice) TableName() string { return "push_devices" }
