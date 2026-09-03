package models

import (
	"fmt"
	"time"

	"gorm.io/gorm"
)

const (
	RetiredNotificationTypeMarketPost     = "market_post"
	RetiredNotificationTypeCanteenPending = "canteen_pending"
	legacyNotificationCleanupBatch        = 500
)

// NotificationTypeCourseEvaluationResult 课程评价审核结果通知。
// 该类型不关联帖子：PostID 恒为 0，RelatedID 为课程评价提交 ID，
// 客户端必须按 related_id 深链到"我的内容 → 学科评价"，不能当作帖子 ID 使用。
const NotificationTypeCourseEvaluationResult = "course_evaluation_result"

// RetiredNotificationTypes 已退役通知类型：不再产生，查询时过滤并分批清理历史数据。
var RetiredNotificationTypes = []string{
	RetiredNotificationTypeMarketPost,
	RetiredNotificationTypeCanteenPending,
}

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

// PurgeRetiredNotifications 分批清理已退役类型的通知，避免单次删除长期占用数据库锁。
func PurgeRetiredNotifications(db *gorm.DB) (int64, error) {
	var total int64
	for _, retiredType := range RetiredNotificationTypes {
		for {
			var ids []uint
			if err := db.Model(&Notification{}).
				Where("type = ?", retiredType).
				Order("id ASC").
				Limit(legacyNotificationCleanupBatch).
				Pluck("id", &ids).Error; err != nil {
				return total, err
			}
			if len(ids) == 0 {
				break
			}

			result := db.Where("id IN ?", ids).Delete(&Notification{})
			if result.Error != nil {
				return total, result.Error
			}
			if result.RowsAffected == 0 {
				return total, fmt.Errorf("退役通知清理未取得进展")
			}
			total += result.RowsAffected
		}
	}
	return total, nil
}
