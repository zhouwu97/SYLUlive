package models

import "time"

const (
	EmojiPackPending     = "pending"
	EmojiPackPublished   = "published"
	EmojiPackRejected    = "rejected"
	EmojiPackUnpublished = "unpublished"
	EmojiPackWithdrawn   = "withdrawn"
	EmojiPackSuperseded  = "superseded"
)

// CommunityEmojiPack 的审核状态是专用资源路由的访问依据，不授予普通 File 公开权限。
type CommunityEmojiPack struct {
	ID              string                    `gorm:"size:64;primaryKey" json:"id"`
	UserID          uint                      `gorm:"not null;index;uniqueIndex:idx_emoji_pack_request,priority:1" json:"user_id"`
	FamilyID        string                    `gorm:"size:64;index" json:"pack_id"`
	Version         int                       `gorm:"not null;default:1" json:"version"`
	CoverAssetID    string                    `gorm:"size:64" json:"cover_asset_id"`
	IconAssetID     string                    `gorm:"size:64" json:"icon_asset_id"`
	AuthorName      string                    `gorm:"size:1200" json:"author_name"`
	Tags            []string                  `gorm:"serializer:json;type:text" json:"tags"`
	MediaVersion    int                       `gorm:"not null;default:0" json:"media_version"`
	CreatorRequired bool                      `gorm:"not null;default:false" json:"-"`
	RequestKey      string                    `gorm:"size:64;not null;uniqueIndex:idx_emoji_pack_request,priority:2" json:"-"`
	ContentHash     string                    `gorm:"size:64;not null" json:"-"`
	Name            string                    `gorm:"size:1200;not null" json:"name"`
	Description     string                    `gorm:"size:6000" json:"description"`
	Status          string                    `gorm:"size:20;not null;index" json:"status"`
	AssetCount      int                       `gorm:"not null" json:"asset_count"`
	TotalSize       int64                     `gorm:"not null" json:"total_size"`
	StorageSize     int64                     `gorm:"not null;default:0" json:"-"`
	Manifest        []byte                    `json:"-"`
	ManifestSHA256  string                    `gorm:"size:64;not null" json:"manifest_sha256"`
	ReviewReason    string                    `gorm:"size:500" json:"review_reason"`
	ReviewedBy      *uint                     `json:"reviewed_by,omitempty"`
	ReviewedAt      *time.Time                `json:"reviewed_at,omitempty"`
	CreatedAt       time.Time                 `json:"created_at"`
	UpdatedAt       time.Time                 `json:"updated_at"`
	Assets          []CommunityEmojiPackAsset `gorm:"foreignKey:PackID" json:"assets,omitempty"`
}

// CatalogID 兼容升级前没有版本族字段的 v1 投稿。
func (p CommunityEmojiPack) CatalogID() string {
	if p.FamilyID != "" {
		return p.FamilyID
	}
	return p.ID
}

const (
	EmojiCreatorPending   = "pending"
	EmojiCreatorActive    = "active"
	EmojiCreatorRejected  = "rejected"
	EmojiCreatorSuspended = "suspended"
)

type EmojiCreator struct {
	UserID       uint       `gorm:"primaryKey" json:"user_id"`
	Description  string     `gorm:"size:6000;not null" json:"description"`
	Status       string     `gorm:"size:20;not null;index" json:"status"`
	Version      int        `gorm:"not null;default:1" json:"version"`
	ReviewReason string     `gorm:"size:500" json:"review_reason"`
	ReviewedBy   *uint      `json:"reviewed_by,omitempty"`
	ReviewedAt   *time.Time `json:"reviewed_at,omitempty"`
	CreatedAt    time.Time  `json:"created_at"`
	UpdatedAt    time.Time  `json:"updated_at"`
}

type CommunityEmojiPackAsset struct {
	ID       uint   `gorm:"primaryKey" json:"-"`
	PackID   string `gorm:"size:64;not null;uniqueIndex:idx_community_emoji_asset,priority:1" json:"-"`
	AssetID  string `gorm:"size:64;not null;uniqueIndex:idx_community_emoji_asset,priority:2" json:"id"`
	Name     string `gorm:"size:1200;not null" json:"name"`
	SHA256   string `gorm:"size:64;not null" json:"sha256"`
	MimeType string `gorm:"size:40;not null" json:"mime_type"`
	FileSize int    `gorm:"not null" json:"file_size"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
	Animated bool   `json:"animated"`
}
