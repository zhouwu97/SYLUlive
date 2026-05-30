package models

import "time"

// SystemConfig 系统动态配置表
type SystemConfig struct {
	ConfigKey   string    `gorm:"primaryKey;type:varchar(64)" json:"config_key"`
	ConfigValue string    `gorm:"type:text" json:"config_value"` // 存储大段的 JS 脚本
	Description string    `gorm:"type:varchar(255)" json:"description"`
	UpdatedAt   time.Time `json:"updated_at"`
}
