package models

import (
	"errors"
	"time"

	"gorm.io/gorm"
)

// IdempotencyRecord 保存带 Idempotency-Key 的写请求及其最终响应。
//
// 记录同时承担并发请求的占位锁和响应缓存：首个请求创建 processing 记录，
// 后续同键请求等待并重放 completed 响应。请求范围包含 method/path，避免同一
// 个键误用于不同业务接口。
type IdempotencyRecord struct {
	ID uint `gorm:"primaryKey" json:"-"`

	Scope        string `gorm:"size:160;not null;uniqueIndex:idx_idempotency_scope_key_route,priority:1" json:"-"`
	Key          string `gorm:"column:idempotency_key;size:200;not null;uniqueIndex:idx_idempotency_scope_key_route,priority:2" json:"-"`
	Method       string `gorm:"size:12;not null;uniqueIndex:idx_idempotency_scope_key_route,priority:3" json:"-"`
	Path         string `gorm:"size:512;not null;uniqueIndex:idx_idempotency_scope_key_route,priority:4" json:"-"`
	RequestHash  string `gorm:"size:64;not null" json:"-"`
	State        string `gorm:"size:20;not null;index" json:"-"`
	ResponseCode int    `gorm:"not null;default:200" json:"-"`
	ContentType  string `gorm:"size:160;not null;default:''" json:"-"`
	ResponseBody []byte `gorm:"type:bytea" json:"-"`
	// 给旧表补列时使用数据库当前时间，避免已有 processing 记录导致 NOT NULL 迁移失败。
	ExpiresAt time.Time `gorm:"not null;default:CURRENT_TIMESTAMP;index" json:"-"`
	CreatedAt time.Time `json:"-"`
	UpdatedAt time.Time `json:"-"`
}

func (IdempotencyRecord) TableName() string { return "idempotency_records" }

const (
	IdempotencyStateProcessing = "processing"
	IdempotencyStateCompleted  = "completed"
	IdempotencyStateFailed     = "failed"
)

// EnsureIdempotencySchema 是启动迁移的单一入口，必须可重复执行。
func EnsureIdempotencySchema(db *gorm.DB) error {
	if db == nil {
		return errors.New("idempotency schema migration requires database")
	}
	return db.AutoMigrate(&IdempotencyRecord{})
}
