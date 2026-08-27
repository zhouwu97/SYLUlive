package models

import "time"

// ImageVariantStatus 描述持久化图片变体任务的生命周期。
type ImageVariantStatus string

const (
	ImageVariantStatusPending     ImageVariantStatus = "pending"
	ImageVariantStatusRunning     ImageVariantStatus = "running"
	ImageVariantStatusReady       ImageVariantStatus = "ready"
	ImageVariantStatusFailed      ImageVariantStatus = "failed"
	ImageVariantStatusUnsupported ImageVariantStatus = "unsupported"
)

// ImageVariant 保存可公开读取图片的版本化静态变体及其生成状态。
// 同一文件、变体名称与配方版本只能有一条记录，避免重复生成和旧配方互相覆盖。
type ImageVariant struct {
	ID            uint               `gorm:"primaryKey" json:"id"`
	FileID        uint               `gorm:"not null;uniqueIndex:idx_image_variant_recipe,priority:1" json:"file_id"`
	Variant       string             `gorm:"size:16;not null;uniqueIndex:idx_image_variant_recipe,priority:2" json:"variant"`
	RecipeVersion int                `gorm:"not null;uniqueIndex:idx_image_variant_recipe,priority:3" json:"recipe_version"`
	Status        ImageVariantStatus `gorm:"size:16;not null;default:'pending';check:chk_image_variant_status,status IN ('pending','running','ready','failed','unsupported');index" json:"status"`
	Path          string             `gorm:"size:500;not null" json:"path"`
	MimeType      string             `gorm:"size:100;not null" json:"mime_type"`
	Width         int                `gorm:"not null;default:0" json:"width"`
	Height        int                `gorm:"not null;default:0" json:"height"`
	Size          int64              `gorm:"not null;default:0" json:"size"`
	Attempts      int                `gorm:"not null;default:0" json:"attempts"`
	NextAttemptAt *time.Time         `gorm:"index" json:"next_attempt_at,omitempty"`
	StartedAt     *time.Time         `gorm:"index" json:"started_at,omitempty"`
	LastError     string             `gorm:"size:2000;not null;default:''" json:"last_error"`
	CreatedAt     time.Time          `json:"created_at"`
	UpdatedAt     time.Time          `json:"updated_at"`
}
