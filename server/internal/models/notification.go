package models

import (
	"fmt"
	"time"

	"gorm.io/gorm"
)

const (
	RetiredNotificationTypeMarketPost = "market_post"
	legacyNotificationCleanupBatch    = 500
)

// Notification 用户通知模型
type Notification struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	UserID    uint      `gorm:"not null;index" json:"user_id"`      // 接收通知的用户
	Type      string    `gorm:"size:50;not null;index" json:"type"` // 通知类型: reply
	Content   string    `gorm:"type:text" json:"content"`           // 通知内容摘要
	RelatedID uint      `gorm:"index" json:"related_id"`            // 关联对象ID（如回复ID）
	DedupKey  string    `gorm:"size:191;index" json:"-"`            // 业务事件去重键
	PostID    uint      `gorm:"index" json:"post_id"`               // 关联帖子ID
	FromUID   uint      `gorm:"index" json:"from_uid"`              // 发起人用户ID
	IsRead    bool      `gorm:"default:false;index" json:"is_read"` // 是否已读
	CreatedAt time.Time `json:"created_at"`
}

// PurgeLegacyMarketPostNotifications 分批清理已退役的集市广播通知，避免单次删除长期占用数据库锁。
func PurgeLegacyMarketPostNotifications(db *gorm.DB) (int64, error) {
	var total int64
	for {
		var ids []uint
		if err := db.Model(&Notification{}).
			Where("type = ?", RetiredNotificationTypeMarketPost).
			Order("id ASC").
			Limit(legacyNotificationCleanupBatch).
			Pluck("id", &ids).Error; err != nil {
			return total, err
		}
		if len(ids) == 0 {
			return total, nil
		}

		result := db.Where("id IN ?", ids).Delete(&Notification{})
		if result.Error != nil {
			return total, result.Error
		}
		if result.RowsAffected == 0 {
			return total, fmt.Errorf("集市广播通知清理未取得进展")
		}
		total += result.RowsAffected
	}
}
