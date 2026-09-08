package models

import "time"

// AcademicAccountConfig 是用户自报的跨设备配置，不授予任何学生身份权限。
// 删除保留原行及 revision，避免离线旧写入在重建后重新生效。
type AcademicAccountConfig struct {
	ID         uint       `gorm:"primaryKey" json:"id"`
	UserID     uint       `gorm:"not null;uniqueIndex:ux_academic_config_owner,priority:1" json:"-"`
	ProviderID string     `gorm:"size:64;not null;uniqueIndex:ux_academic_config_owner,priority:2" json:"provider_id"`
	StudentID  string     `gorm:"size:128;not null" json:"student_id"`
	State      string     `gorm:"size:16;not null" json:"state"`
	Revision   uint64     `gorm:"not null" json:"revision"`
	CreatedAt  time.Time  `json:"created_at"`
	UpdatedAt  time.Time  `json:"updated_at"`
	DeletedAt  *time.Time `json:"deleted_at,omitempty"`
}

// AcademicConfigReceipt 与配置在同一事务提交，保障长时间离线后的原操作重放。
type AcademicConfigReceipt struct {
	ID          uint   `gorm:"primaryKey"`
	UserID      uint   `gorm:"not null;uniqueIndex:ux_academic_config_operation,priority:1"`
	OperationID string `gorm:"size:128;not null;uniqueIndex:ux_academic_config_operation,priority:2"`
	RequestHash string `gorm:"size:64;not null"`
	Result      string `gorm:"type:text;not null"`
	CreatedAt   time.Time
}
