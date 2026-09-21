package services

import (
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestSecurityEventAggregatesWithoutPersistingRawSource(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}, &models.SecurityBlock{}); err != nil {
		t.Fatalf("迁移安全表失败: %v", err)
	}
	now := time.Date(2026, time.July, 22, 12, 0, 0, 0, time.UTC)
	service := NewSecurityEventService(db, "security-test-secret", func() time.Time { return now })
	for i := 0; i < 2; i++ {
		if err := service.Record(SecurityEventInput{
			EventType: "password_reset_spray", Severity: models.SecuritySeverityHigh,
			Route: "/api/password/email/code", Method: "POST", ClientIP: "203.0.113.8",
			TargetType: "email", TargetValue: "target@example.com", TargetMasked: "ta***om@example.com", Blocked: i == 1,
		}); err != nil {
			t.Fatalf("写入安全事件失败: %v", err)
		}
	}
	var events []models.SecurityEvent
	if err := db.Find(&events).Error; err != nil {
		t.Fatalf("读取安全事件失败: %v", err)
	}
	if len(events) != 1 || events[0].AttemptCount != 2 || events[0].BlockedCount != 1 {
		t.Fatalf("聚合结果错误: %+v", events)
	}
	if events[0].SourceIPHash == "" || events[0].TargetHash == "" || events[0].SourceIPHash == "203.0.113.8" {
		t.Fatalf("安全事件不应保存明文来源: %+v", events[0])
	}
}

func TestSecurityEventMailCallbackDoesNotDoubleCountRequest(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}); err != nil {
		t.Fatalf("迁移安全表失败: %v", err)
	}
	now := time.Date(2026, time.July, 22, 12, 0, 0, 0, time.UTC)
	service := NewSecurityEventService(db, "security-test-secret", func() time.Time { return now })
	input := SecurityEventInput{
		EventType: "password_reset_activity", Route: "/api/password/email/code", Method: "POST",
		ClientIP: "203.0.113.8", TargetType: "email", TargetValue: "target@example.com",
	}
	if err := service.Record(input); err != nil {
		t.Fatalf("写入请求事件失败: %v", err)
	}
	input.SkipAttempt = true
	input.MailSent = true
	input.Action = "mail_sent"
	if err := service.Record(input); err != nil {
		t.Fatalf("写入邮件事件失败: %v", err)
	}
	var event models.SecurityEvent
	if err := db.First(&event).Error; err != nil {
		t.Fatalf("读取聚合事件失败: %v", err)
	}
	if event.AttemptCount != 1 || event.MailSentCount != 1 {
		t.Fatalf("请求和邮件计数错误: %+v", event)
	}
}

func TestSecurityEventReactivationClearsResolutionFields(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}); err != nil {
		t.Fatalf("迁移安全表失败: %v", err)
	}
	now := time.Date(2026, time.July, 22, 12, 0, 0, 0, time.UTC)
	service := NewSecurityEventService(db, "security-test-secret", func() time.Time { return now })
	input := SecurityEventInput{EventType: "verification_spray", Severity: models.SecuritySeverityHigh,
		Route: "/api/register/email/code", Method: "POST", ClientIP: "203.0.113.30", TargetValue: "a@example.com"}
	if err := service.Record(input); err != nil {
		t.Fatalf("写入安全事件失败: %v", err)
	}
	var event models.SecurityEvent
	if err := db.First(&event).Error; err != nil {
		t.Fatalf("读取待处置安全事件失败: %v", err)
	}
	var resolvedAt time.Time
	if err := db.Model(&models.SecurityEvent{}).Where("id = ?", event.ID).Updates(map[string]interface{}{
		"status": models.SecurityEventStatusResolved, "resolved_at": &resolvedAt,
		"resolved_by": uint(7), "resolution_note": "已处理",
	}).Error; err != nil {
		t.Fatalf("设置处置状态失败: %v", err)
	}
	if err := service.Record(input); err != nil {
		t.Fatalf("重新写入安全事件失败: %v", err)
	}
	if err := db.First(&event).Error; err != nil {
		t.Fatalf("读取安全事件失败: %v", err)
	}
	if event.Status != models.SecurityEventStatusActive || event.ResolvedAt != nil || event.ResolvedBy != nil || event.ResolutionNote != "" {
		t.Fatalf("安全事件重新激活后仍残留旧处置状态: %+v", event)
	}
}
