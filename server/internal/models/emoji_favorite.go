package models

import "time"

const (
	EmojiFavoriteKindBuiltin = "builtin"
	EmojiFavoriteKindCustom  = "custom"
)

// UserEmojiAsset 记录用户将文件作为自定义表情使用时的派生资源信息。
type UserEmojiAsset struct {
	ID            uint      `gorm:"primaryKey" json:"id"`
	UserID        uint      `gorm:"not null;uniqueIndex:idx_user_emoji_assets_user_file,priority:1" json:"user_id"`
	FileID        uint      `gorm:"not null;uniqueIndex:idx_user_emoji_assets_user_file,priority:2" json:"file_id"`
	ThumbnailPath string    `gorm:"size:500" json:"thumbnail_path"`
	MimeType      string    `gorm:"size:100;not null" json:"mime_type"`
	IsAnimated    bool      `gorm:"not null;default:false" json:"is_animated"`
	Width         int       `gorm:"not null" json:"width"`
	Height        int       `gorm:"not null" json:"height"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// UserEmojiFavorite 记录用户收藏的内置贴纸或自定义表情资源。
// 两个条件唯一索引分别约束非空的 builtin sticker 与 custom asset，规避 NULL 唯一性差异。
type UserEmojiFavorite struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	UserID    uint      `gorm:"not null;index;uniqueIndex:idx_user_emoji_favorites_builtin,priority:1;uniqueIndex:idx_user_emoji_favorites_custom,priority:1" json:"user_id"`
	Kind      string    `gorm:"size:16;not null;index;uniqueIndex:idx_user_emoji_favorites_builtin,priority:2;uniqueIndex:idx_user_emoji_favorites_custom,priority:2" json:"kind"`
	StickerID *string   `gorm:"size:100;uniqueIndex:idx_user_emoji_favorites_builtin,priority:3,where:kind = 'builtin' AND sticker_id IS NOT NULL" json:"sticker_id,omitempty"`
	AssetID   *uint     `gorm:"uniqueIndex:idx_user_emoji_favorites_custom,priority:3,where:kind = 'custom' AND asset_id IS NOT NULL" json:"asset_id,omitempty"`
	SortOrder int64     `gorm:"not null;default:0" json:"sort_order"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}
