package models

import "time"

// LoginThrottleRecord 是跨实例共享的登录失败计数；Scope 只保存摘要，不保存原始账号或 IP。
type LoginThrottleRecord struct {
	ID            uint       `gorm:"primaryKey"`
	Scope         string     `gorm:"size:128;not null;uniqueIndex"`
	FailureCount  int        `gorm:"not null;default:0"`
	LockedUntil   *time.Time `gorm:"index"`
	LastFailureAt *time.Time `gorm:"index"`
	UpdatedAt     time.Time
}
