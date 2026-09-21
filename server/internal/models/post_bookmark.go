package models

import "time"

// PostBookmark 用联合主键保证重复收藏不会生成多条记录。
type PostBookmark struct {
	UserID    uint      `gorm:"primaryKey;autoIncrement:false" json:"user_id"`
	PostID    uint      `gorm:"primaryKey;autoIncrement:false;index" json:"post_id"`
	CreatedAt time.Time `json:"created_at"`
}
