package models

import (
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestPurgeLegacyMarketPostNotifications(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&Notification{}); err != nil {
		t.Fatalf("迁移通知表失败: %v", err)
	}

	legacyNotifications := make([]Notification, legacyNotificationCleanupBatch+1)
	for i := range legacyNotifications {
		legacyNotifications[i] = Notification{
			UserID: uint(i + 1),
			Type:   RetiredNotificationTypeMarketPost,
		}
	}
	if err := db.CreateInBatches(&legacyNotifications, 100).Error; err != nil {
		t.Fatalf("写入历史集市通知失败: %v", err)
	}
	if err := db.Create(&Notification{UserID: 1, Type: "reply"}).Error; err != nil {
		t.Fatalf("写入保留通知失败: %v", err)
	}

	removed, err := PurgeLegacyMarketPostNotifications(db)
	if err != nil {
		t.Fatalf("清理历史集市通知失败: %v", err)
	}
	if removed != int64(len(legacyNotifications)) {
		t.Fatalf("清理数量=%d，期望=%d", removed, len(legacyNotifications))
	}

	var marketCount int64
	if err := db.Model(&Notification{}).
		Where("type = ?", RetiredNotificationTypeMarketPost).
		Count(&marketCount).Error; err != nil {
		t.Fatalf("统计历史集市通知失败: %v", err)
	}
	if marketCount != 0 {
		t.Fatalf("仍有 %d 条历史集市通知", marketCount)
	}

	var replyCount int64
	if err := db.Model(&Notification{}).Where("type = ?", "reply").Count(&replyCount).Error; err != nil {
		t.Fatalf("统计回复通知失败: %v", err)
	}
	if replyCount != 1 {
		t.Fatalf("回复通知数量=%d，期望=1", replyCount)
	}

	removed, err = PurgeLegacyMarketPostNotifications(db)
	if err != nil {
		t.Fatalf("重复清理失败: %v", err)
	}
	if removed != 0 {
		t.Fatalf("重复清理数量=%d，期望=0", removed)
	}
}
