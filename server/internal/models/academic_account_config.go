package models

import (
	"gorm.io/gorm"
	"time"
)

// AcademicAccountConfig 记录跨设备教务配置，也是校内功能的准入依据。配置不证明学号归属。
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

// ActiveAcademicConfigs 只从受支持的教务配置判断校内准入。删除墓碑保留版本，但不授予资格。
func ActiveAcademicConfigs(db *gorm.DB) *gorm.DB {
	return db.Model(&AcademicAccountConfig{}).Where("state = ? AND TRIM(student_id) <> '' AND provider_id IN ?", "active", []string{AcademicProviderUndergraduate, AcademicProviderGraduate})
}

func HasAcademicConfig(db *gorm.DB, userID uint) (bool, error) {
	var count int64
	err := ActiveAcademicConfigs(db).Where("user_id = ?", userID).Count(&count).Error
	return count > 0, err
}
