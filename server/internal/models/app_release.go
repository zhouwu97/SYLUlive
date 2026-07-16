package models

import "time"

// App release status constants.
const (
	AppReleaseStatusDraft     = "draft"
	AppReleaseStatusPublished = "published"
	AppReleaseStatusWithdrawn  = "withdrawn"
)

// Platform and channel constants for the first version. Kept as fields so that
// future channels can be added without altering the schema.
const (
	AppReleasePlatformAndroid = "android"
	AppReleaseChannelStable   = "stable"
)

// AppRelease represents a single APK artifact published through the server.
//
// A published row is the only source of truth for whether a specific
// (platform, channel, version_code) can be downloaded. The latest published
// row (highest version_code) in the channel drives the update decision, while
// MinimumSupportedVersionCode drives the 426 fallback handled in a later phase.
type AppRelease struct {
	ID uint `gorm:"primaryKey" json:"id"`

	Platform string `gorm:"type:varchar(16);not null;index" json:"platform"`
	Channel  string `gorm:"type:varchar(16);not null;index" json:"channel"`

	VersionName string `gorm:"type:varchar(32);not null" json:"version_name"`
	VersionCode int64  `gorm:"not null" json:"version_code"`

	Title     string `gorm:"type:varchar(120);not null" json:"title"`
	Changelog string `gorm:"type:text;not null" json:"changelog"`

	MinimumSupportedVersionCode int64 `gorm:"not null" json:"minimum_supported_version_code"`

	FileName   string `gorm:"type:varchar(255);not null" json:"file_name"`
	StorageKey string `gorm:"type:varchar(255);not null" json:"storage_key"`
	FileSize   int64  `gorm:"not null" json:"file_size"`
	SHA256     string `gorm:"type:char(64);not null" json:"sha256"`

	Status string `gorm:"type:varchar(16);not null;index" json:"status"`

	CreatedBy    uint       `json:"created_by"`
	PublishedAt  *time.Time `json:"published_at"`
	CreatedAt    time.Time  `json:"created_at"`
	UpdatedAt    time.Time  `json:"updated_at"`
}