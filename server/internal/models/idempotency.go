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

// CleanupExpiredIdempotencyRecords 回收已过期的响应缓存，并把已超时的占位记录
// 标记为 failed。processing 记录不会直接删除，避免业务请求仍在执行时释放唯一键，
// 让重试重新进入业务副作用。
func CleanupExpiredIdempotencyRecords(db *gorm.DB, now time.Time, batchSize int) (int64, error) {
	if db == nil {
		return 0, errors.New("idempotency cleanup requires database")
	}
	if batchSize <= 0 {
		batchSize = 500
	}

	var expiredProcessingIDs []uint
	if err := db.Model(&IdempotencyRecord{}).
		Where("state = ? AND expires_at <= ?", IdempotencyStateProcessing, now).
		Pluck("id", &expiredProcessingIDs).Error; err != nil {
		return 0, err
	}
	if len(expiredProcessingIDs) > 0 {
		if err := db.Model(&IdempotencyRecord{}).
			Where("id IN ? AND state = ?", expiredProcessingIDs, IdempotencyStateProcessing).
			Update("state", IdempotencyStateFailed).Error; err != nil {
			return 0, err
		}
	}

	query := db.Model(&IdempotencyRecord{}).
		Where("state <> ? AND expires_at <= ?", IdempotencyStateProcessing, now).
		Order("id ASC").
		Limit(batchSize)
	if len(expiredProcessingIDs) > 0 {
		query = query.Where("id NOT IN ?", expiredProcessingIDs)
	}
	var ids []uint
	if err := query.Pluck("id", &ids).Error; err != nil {
		return 0, err
	}
	if len(ids) == 0 {
		return 0, nil
	}
	result := db.Where("id IN ?", ids).Delete(&IdempotencyRecord{})
	return result.RowsAffected, result.Error
}
