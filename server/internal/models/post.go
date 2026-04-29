package models

import (
	"time"
)

// BoardID 板块ID
type BoardID int

const (
	BoardShuitie BoardID = 1 // 水贴
	BoardMarket  BoardID = 2 // 校园集市
	BoardScam    BoardID = 3 // 骗子曝光（占位）
	BoardNotice  BoardID = 4 // 公告
)

// PostStatus 帖子状态
type PostStatus string

const (
	PostStatusNormal  PostStatus = "normal"  // 正常
	PostStatusDeleted PostStatus = "deleted" // 已删除
)

// Post 帖子模型
type Post struct {
	ID        uint        `gorm:"primaryKey" json:"id"`
	Title     string      `gorm:"size:200" json:"title"`              // 标题（水贴可为空）
	Content   string      `gorm:"type:text" json:"content"`           // Markdown内容
	BoardID   BoardID     `gorm:"not null;index" json:"board_id"`     // 板块ID
	AuthorID  uint        `gorm:"not null;index" json:"author_id"`    // 作者ID
	PostType  string      `gorm:"size:50;index" json:"post_type"`     // marketplace_buy/sell, course_proxy 等
	Price     float64     `gorm:"default:0" json:"price"`             // 价格（校园集市用）
	Contact   string      `gorm:"size:500" json:"contact"`            // 联系方式
	Status    PostStatus  `gorm:"default:normal;index" json:"status"` // 状态
	Images    []PostImage `gorm:"foreignKey:PostID" json:"images"`
	Author    User        `gorm:"foreignKey:AuthorID" json:"author"`
	CreatedAt time.Time   `json:"created_at"`
	UpdatedAt time.Time   `json:"updated_at"`
}

// PostImage 帖子图片关联
type PostImage struct {
	ID        uint `gorm:"primaryKey" json:"id"`
	PostID    uint `gorm:"not null" json:"post_id"`
	FileID    uint `gorm:"not null" json:"file_id"`
	SortOrder int  `gorm:"default:0" json:"sort_order"`
	File      File `gorm:"foreignKey:FileID" json:"file"`
}
