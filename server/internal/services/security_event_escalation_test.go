package services

import (
	"strings"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// 同一五分钟聚合桶里的 severity / action 必须单向升级。
//
// 这条缺陷曾经在生产表现为：一个桶里先记了 medium+observed 的普通失败，
// 随后同桶的第三次失败已经真正触发拦截（high+blocked），但数据库只累加了
// blocked_count，severity 仍是 medium、action 仍是 observed。
// 首页「高危待处理」直接按 severity 统计，于是已经拦截掉的攻击反而被漏报。
func TestSecurityEventAggregationEscalatesSeverityAndAction(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}); err != nil {
		t.Fatalf("迁移安全表失败: %v", err)
	}
	// 07:44 与 07:45 落在同一个五分钟桶（07:40~07:45 与 07:45~07:50 不同，
	// 因此这里用同一分钟内的时间点确保两条事件确实同桶）。
	now := time.Date(2026, time.July, 22, 7, 44, 10, 0, time.UTC)
	service := NewSecurityEventService(db, "security-test-secret", func() time.Time { return now })

	base := SecurityEventInput{
		EventType: "login_bruteforce", Route: "/api/login", Method: "POST",
		ClientIP: "203.0.113.9", TargetType: "account", TargetValue: "student-a",
	}
	observed := base
	observed.Severity = models.SecuritySeverityMedium
	observed.Action = "observed"
	observed.Metadata = map[string]interface{}{"failure_count": 1}
	if err := service.Record(observed); err != nil {
		t.Fatalf("写入首次观察失败: %v", err)
	}

	now = now.Add(20 * time.Second)
	blocked := base
	blocked.Severity = models.SecuritySeverityHigh
	blocked.Action = "blocked"
	blocked.Blocked = true
	blocked.Metadata = map[string]interface{}{"failure_count": 3}
	if err := service.Record(blocked); err != nil {
		t.Fatalf("写入升级事件失败: %v", err)
	}

	event := loadSingleSecurityEvent(t, db)
	if event.Severity != models.SecuritySeverityHigh {
		t.Fatalf("同桶升级后 severity 应为 high，实际 %q", event.Severity)
	}
	if event.Action != "blocked" {
		t.Fatalf("同桶升级后 action 应为 blocked，实际 %q", event.Action)
	}
	if event.AttemptCount != 2 || event.BlockedCount != 1 {
		t.Fatalf("计数应继续累加: attempts=%d blocked=%d", event.AttemptCount, event.BlockedCount)
	}
	if !strings.Contains(event.MetadataJSON, `"failure_count":3`) {
		t.Fatalf("升级事件的 metadata 应覆盖旧值，实际 %q", event.MetadataJSON)
	}
}

// 反向情况：高等级事件之后到来的低等级观察不能把等级降回去。
func TestSecurityEventAggregationNeverDowngrades(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}); err != nil {
		t.Fatalf("迁移安全表失败: %v", err)
	}
	now := time.Date(2026, time.July, 22, 9, 2, 0, 0, time.UTC)
	service := NewSecurityEventService(db, "security-test-secret", func() time.Time { return now })

	base := SecurityEventInput{
		EventType: "verification_spray", Route: "/api/password/email/code", Method: "POST",
		ClientIP: "203.0.113.10", TargetType: "email", TargetValue: "victim@example.com",
	}
	high := base
	high.Severity = models.SecuritySeverityHigh
	high.Action = "blocked"
	high.Blocked = true
	high.Metadata = map[string]interface{}{"threshold": 8}
	if err := service.Record(high); err != nil {
		t.Fatalf("写入高危事件失败: %v", err)
	}

	low := base
	low.Severity = models.SecuritySeverityLow
	low.Action = "observed"
	// 低等级且不带 metadata：既不能降级，也不能把已有上下文清空。
	if err := service.Record(low); err != nil {
		t.Fatalf("写入低等级观察失败: %v", err)
	}

	event := loadSingleSecurityEvent(t, db)
	if event.Severity != models.SecuritySeverityHigh || event.Action != "blocked" {
		t.Fatalf("低等级观察不得降级已有事件: severity=%q action=%q", event.Severity, event.Action)
	}
	if !strings.Contains(event.MetadataJSON, `"threshold":8`) {
		t.Fatalf("空 metadata 不得清空已有上下文，实际 %q", event.MetadataJSON)
	}
}

// 同一桶内 action 也应单向升级：先 observed 后 throttled 必须落到已限流。
func TestSecurityEventAggregationEscalatesObservedToThrottled(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}); err != nil {
		t.Fatalf("迁移安全表失败: %v", err)
	}
	now := time.Date(2026, time.July, 22, 5, 31, 0, 0, time.UTC)
	service := NewSecurityEventService(db, "security-test-secret", func() time.Time { return now })

	base := SecurityEventInput{
		EventType: "verification_source_rate", Route: "email_verification", Method: "POST",
		ClientIP: "203.0.113.11", TargetType: "email", TargetValue: "user@example.com",
	}
	first := base
	first.Severity = models.SecuritySeverityLow
	first.Action = "observed"
	if err := service.Record(first); err != nil {
		t.Fatalf("写入首次观察失败: %v", err)
	}
	second := base
	second.Severity = models.SecuritySeverityMedium
	second.Action = "throttled"
	second.Blocked = true
	if err := service.Record(second); err != nil {
		t.Fatalf("写入限流事件失败: %v", err)
	}

	event := loadSingleSecurityEvent(t, db)
	if event.Action != "throttled" || event.Severity != models.SecuritySeverityMedium {
		t.Fatalf("action 应升级为 throttled、severity 升级为 medium，实际 action=%q severity=%q",
			event.Action, event.Severity)
	}
}

// 密码喷洒判据必须同时覆盖 login_failed 与 login_bruteforce。
// 只统计后者会漏掉「已经在批量试账号、但每个账号都还没触发锁定」的扫描。
func TestCountDistinctTargetsForEventsSpansLoginFailureLevels(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}); err != nil {
		t.Fatalf("迁移安全表失败: %v", err)
	}
	now := time.Date(2026, time.July, 22, 10, 0, 0, 0, time.UTC)
	service := NewSecurityEventService(db, "security-test-secret", func() time.Time { return now })

	for i := 0; i < 6; i++ {
		if err := service.Record(SecurityEventInput{
			EventType: "login_failed", Severity: models.SecuritySeverityLow,
			Route: "/api/login", Method: "POST", ClientIP: "203.0.113.12",
			TargetType: "account", TargetValue: "account-" + string(rune('a'+i)),
		}); err != nil {
			t.Fatalf("写入普通失败失败: %v", err)
		}
	}
	for i := 0; i < 4; i++ {
		if err := service.Record(SecurityEventInput{
			EventType: "login_bruteforce", Severity: models.SecuritySeverityMedium,
			Route: "/api/login", Method: "POST", ClientIP: "203.0.113.12",
			TargetType: "account", TargetValue: "locked-" + string(rune('a'+i)),
			Blocked: true,
		}); err != nil {
			t.Fatalf("写入锁定事件失败: %v", err)
		}
	}

	since := now.Add(-10 * time.Minute)
	count, err := service.CountDistinctTargetsForEvents(
		[]string{"login_failed", "login_bruteforce"}, "203.0.113.12", since)
	if err != nil {
		t.Fatalf("统计不同目标失败: %v", err)
	}
	if count != 10 {
		t.Fatalf("跨等级统计应覆盖 10 个不同账号，实际 %d", count)
	}

	// 其它来源不能计入。
	other, err := service.CountDistinctTargetsForEvents(
		[]string{"login_failed", "login_bruteforce"}, "198.51.100.1", since)
	if err != nil {
		t.Fatalf("统计其它来源失败: %v", err)
	}
	if other != 0 {
		t.Fatalf("其它来源不应被计入，实际 %d", other)
	}
}

func loadSingleSecurityEvent(t *testing.T, db *gorm.DB) models.SecurityEvent {
	t.Helper()
	var events []models.SecurityEvent
	if err := db.Find(&events).Error; err != nil {
		t.Fatalf("读取安全事件失败: %v", err)
	}
	if len(events) != 1 {
		t.Fatalf("同一聚合桶应只有一条事件，实际 %d 条", len(events))
	}
	return events[0]
}
