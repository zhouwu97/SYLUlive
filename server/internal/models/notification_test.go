package models

import (
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestPurgeRetiredNotifications(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&Notification{}); err != nil {
		t.Fatalf("迁移通知表失败: %v", err)
	}

	legacyNotifications := make([]Notification, 0, 2*(legacyNotificationCleanupBatch+1))
	for i := 0; i < legacyNotificationCleanupBatch+1; i++ {
		legacyNotifications = append(legacyNotifications,
			Notification{UserID: uint(i + 1), Type: RetiredNotificationTypeMarketPost},
			Notification{UserID: uint(i + 1), Type: RetiredNotificationTypeCanteenPending},
		)
	}
	if err := db.CreateInBatches(&legacyNotifications, 100).Error; err != nil {
		t.Fatalf("写入退役通知失败: %v", err)
	}
	if err := db.Create(&Notification{UserID: 1, Type: "reply"}).Error; err != nil {
		t.Fatalf("写入保留通知失败: %v", err)
	}

	removed, err := PurgeRetiredNotifications(db)
	if err != nil {
		t.Fatalf("清理退役通知失败: %v", err)
	}
	if removed != int64(len(legacyNotifications)) {
		t.Fatalf("清理数量=%d，期望=%d", removed, len(legacyNotifications))
	}

	var retiredCount int64
	if err := db.Model(&Notification{}).
		Where("type IN ?", RetiredNotificationTypes).
		Count(&retiredCount).Error; err != nil {
		t.Fatalf("统计退役通知失败: %v", err)
	}
	if retiredCount != 0 {
		t.Fatalf("仍有 %d 条退役通知", retiredCount)
	}

	var replyCount int64
	if err := db.Model(&Notification{}).Where("type = ?", "reply").Count(&replyCount).Error; err != nil {
		t.Fatalf("统计回复通知失败: %v", err)
	}
	if replyCount != 1 {
		t.Fatalf("回复通知数量=%d，期望=1", replyCount)
	}

	removed, err = PurgeRetiredNotifications(db)
	if err != nil {
		t.Fatalf("重复清理失败: %v", err)
	}
	if removed != 0 {
		t.Fatalf("重复清理数量=%d，期望=0", removed)
	}
}
