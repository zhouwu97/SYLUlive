package models

import "time"

const (
	ThemeStatusPending    = "pending"
	ThemeStatusApproved   = "approved"
	ThemeStatusRejected   = "rejected"
	ThemeStatusWithdrawn  = "withdrawn"
	ThemeStatusSuperseded = "superseded"
	ThemeStatusRemoved    = "removed"

	ThemeSourceCommunity = "community"
	ThemeSourceOfficial  = "official"
)

// ThemePack 表示一次不可变的主题包投稿记录。
// ID == FamilyID 的首版记录作为整个版本族的根锁锚点与累计下载量载体；
// 同一 FamilyID 下最多只有一条 Status == approved 的记录。
type ThemePack struct {
	ID               string     `gorm:"size:64;primaryKey" json:"id"`
	FamilyID         string     `gorm:"size:64;not null;index;uniqueIndex:idx_theme_family_version,priority:1" json:"familyId"`
	Version          int        `gorm:"not null;uniqueIndex:idx_theme_family_version,priority:2" json:"version"`
	AuthorUserID     uint       `gorm:"not null;index;uniqueIndex:idx_theme_author_idem,priority:1" json:"authorUserId"`
	Name             string     `gorm:"size:120;not null" json:"name"`
	Description      string     `gorm:"size:1000" json:"description"`
	Tags             []string   `gorm:"serializer:json;type:text" json:"tags"`
	License          string     `gorm:"size:32;not null" json:"license"`
	Source           string     `gorm:"size:20;not null;index" json:"source"`
	Status           string     `gorm:"size:20;not null;index" json:"status"`
	MinAppVersion    string     `gorm:"size:32;not null" json:"minAppVersion"`
	FontCopyright    string     `gorm:"size:1000" json:"fontCopyright,omitempty"`
	FontLicenseNote  string     `gorm:"size:2000" json:"fontLicenseNote,omitempty"`
	PackageSHA256    string     `gorm:"size:64;not null" json:"packageSha256"`
	PackageSize      int64      `gorm:"not null" json:"packageSize"`
	ReviewReasonCode string     `gorm:"size:40" json:"reviewReasonCode,omitempty"`
	ReviewNote       string     `gorm:"size:1000" json:"reviewNote,omitempty"`
	ReviewedBy       *uint      `json:"reviewedBy,omitempty"`
	ReviewedAt       *time.Time `json:"reviewedAt,omitempty"`
	IdempotencyKey   string     `gorm:"size:64;not null;uniqueIndex:idx_theme_author_idem,priority:2" json:"-"`
	Downloads        int64      `gorm:"not null;default:0" json:"downloads"`
	CreatedAt        time.Time  `json:"createdAt"`
	UpdatedAt        time.Time  `json:"updatedAt"`
}
