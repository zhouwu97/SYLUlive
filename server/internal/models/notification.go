package models

import (
	"time"
)

// Notification 用户通知模型
type Notification struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	UserID    uint      `gorm:"not null;index" json:"user_id"`          // 接收通知的用户
	Type      string    `gorm:"size:50;not null;index" json:"type"`     // 通知类型: reply
	Content   string    `gorm:"type:text" json:"content"`               // 通知内容摘要
	RelatedID uint      `gorm:"index" json:"related_id"`                // 关联对象ID（如回复ID）
	PostID    uint      `gorm:"index" json:"post_id"`                   // 关联帖子ID
	FromUID   uint      `gorm:"index" json:"from_uid"`                  // 发起人用户ID
	IsRead    bool      `gorm:"default:false;index" json:"is_read"`     // 是否已读
	CreatedAt time.Time `json:"created_at"`
}
