package models

import (
	"time"
)

// ReplyStatus 回复状态
type ReplyStatus string

const (
	ReplyStatusNormal  ReplyStatus = "normal"
	ReplyStatusDeleted ReplyStatus = "deleted"
)

// Reply 回复模型（支持一层嵌套）
type Reply struct {
	ID            uint         `gorm:"primaryKey" json:"id"`
	PostID        uint         `gorm:"not null" json:"post_id"`
	ParentReplyID *uint        `gorm:"index" json:"parent_reply_id"` // 空表示顶级回复
	AuthorID      uint         `gorm:"not null" json:"author_id"`
	Content       string       `gorm:"type:text" json:"content"`
	Status        ReplyStatus  `gorm:"default:normal" json:"status"`
	LikeCount     int          `gorm:"default:0" json:"like_count"`
	IsLiked       bool         `gorm:"-" json:"is_liked"`
	Images        []ReplyImage `gorm:"foreignKey:ReplyID" json:"images"`
	Author        User         `gorm:"foreignKey:AuthorID" json:"author"`
	CreatedAt     time.Time    `json:"created_at"`
	UpdatedAt     time.Time    `json:"updated_at"`
}

// ReplyImage 回复图片关联
type ReplyImage struct {
	ID        uint `gorm:"primaryKey" json:"id"`
	ReplyID   uint `gorm:"not null" json:"reply_id"`
	FileID    uint `gorm:"not null" json:"file_id"`
	SortOrder int  `gorm:"default:0" json:"sort_order"`
	File      File `gorm:"foreignKey:FileID" json:"file"`
}
