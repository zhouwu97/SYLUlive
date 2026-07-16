package models

import "time"

// 应用版本状态常量。
const (
	AppReleaseStatusDraft     = "draft"
	AppReleaseStatusPublished = "published"
	AppReleaseStatusWithdrawn = "withdrawn"
)

// 首版的平台和渠道常量。保留为数据字段，未来增加渠道时无需修改表结构。
const (
	AppReleasePlatformAndroid = "android"
	AppReleasePlatformOhos    = "ohos"
	AppReleaseChannelStable   = "stable"
)

// AppRelease 表示由服务器托管的单个 APK 版本。
// 已发布记录是对应 platform/channel/versionCode 是否可下载的唯一依据；渠道中
// versionCode 最高的已发布版本决定更新目标，MinimumSupportedVersionCode 决定
// 426 最低版本拦截策略。
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

	CreatedBy   uint       `json:"created_by"`
	PublishedAt *time.Time `json:"published_at"`
	CreatedAt   time.Time  `json:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at"`
}
