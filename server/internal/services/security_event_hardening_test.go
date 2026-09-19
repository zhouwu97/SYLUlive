package services

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

var securityEventTestSeq int64

func newSecurityEventTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	// 必须使用 shared cache 的内存库：普通 :memory: 下每个连接各有一份私有库，
	// 并发写入时会看到「no such table」而不是真实的 UPSERT 行为。
	name := fmt.Sprintf("file:security_event_%d?mode=memory&cache=shared", atomic.AddInt64(&securityEventTestSeq, 1))
	db, err := gorm.Open(sqlite.Open(name), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.SecurityEvent{}, &models.SecurityBlock{}))
	return db
}

// SEC-06：只保存白名单字段，不落原始请求体；密钥稳定时同一来源的摘要稳定可复现。
func TestSecurityEventFieldWhitelistAndStableKey(t *testing.T) {
	db := newSecurityEventTestDB(t)
	now := time.Date(2026, time.September, 19, 12, 0, 0, 0, time.UTC)
	service := NewSecurityEventService(db, "stable-hmac-secret", func() time.Time { return now })

	require.NoError(t, service.Record(SecurityEventInput{
		EventType: "content_post_flood", Severity: models.SecuritySeverityMedium,
		Route: "/api/posts", Method: "POST", ClientIP: "198.51.100.9",
		// 故意混入敏感键：这些键必须在写入前被丢弃。
		Metadata: map[string]interface{}{
			"window":         "5m/24h",
			"route_group":    "content",
			"password":       "SuperSecret123",
			"content":        "用户正文不应落库",
			"contact":        "wx_id",
			"access_token":   "eyJhbGciOi",
			"request_body":   "{raw}",
			"email":          "a@b.com",
			"unexpected_key": "x",
		},
	}))

	var event models.SecurityEvent
	require.NoError(t, db.First(&event).Error)
	require.Equal(t, `{"route_group":"content","window":"5m/24h"}`, normalizeMetadataJSON(t, event.MetadataJSON))

	for _, leaked := range []string{"SuperSecret123", "用户正文不应落库", "wx_id", "eyJhbGciOi", "a@b.com"} {
		require.NotContains(t, event.MetadataJSON, leaked, "白名单外字段不得落库：%s", leaked)
	}
	// 来源与目标只保存 HMAC 摘要，不保存明文。
	require.NotContains(t, event.SourceIPHash, "198.51.100.9")
	require.Equal(t, service.Hash("198.51.100.9"), event.SourceIPHash)

	// 同一密钥、同一来源 → 摘要稳定可复现（保证历史事件与现有封禁仍能对上）。
	second := NewSecurityEventService(newSecurityEventTestDB(t), "stable-hmac-secret", func() time.Time { return now })
	require.Equal(t, event.SourceIPHash, second.Hash("198.51.100.9"))
	// 换个密钥就会对不上，因此不得为重构轮换密钥。
	other := NewSecurityEventService(newSecurityEventTestDB(t), "rotated-secret", func() time.Time { return now })
	require.NotEqual(t, event.SourceIPHash, other.Hash("198.51.100.9"))
}

func normalizeMetadataJSON(t *testing.T, raw string) string {
	t.Helper()
	if strings.TrimSpace(raw) == "" {
		return ""
	}
	var decoded map[string]interface{}
	require.NoError(t, json.Unmarshal([]byte(raw), &decoded))
	encoded, err := json.Marshal(decoded)
	require.NoError(t, err)
	return string(encoded)
}

// SEC-05：context 取消时写入与封禁查询有界返回，不无界等待。
func TestSecurityEventBoundedByContext(t *testing.T) {
	db := newSecurityEventTestDB(t)
	now := time.Now()
	service := NewSecurityEventService(db, "secret", func() time.Time { return now })

	cancelled, cancel := context.WithCancel(context.Background())
	cancel()

	done := make(chan error, 1)
	go func() {
		done <- service.RecordContext(cancelled, SecurityEventInput{
			EventType: "security_blocked_request", Severity: models.SecuritySeverityHigh,
			Route: "/api/posts", ClientIP: "203.0.113.1",
		})
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("context 已取消时写入必须立即返回，不能无界等待")
	}

	blocked, err := service.IsBlockedContext(cancelled, "203.0.113.1", "/api/posts")
	require.Error(t, err, "已取消的 context 下封禁查询必须报错而不是静默放行")
	require.False(t, blocked)
}

// SEC-04（单进程部分）：同一五分钟桶的并发 UPSERT 计数必须准确，不因去掉全局
// mutex 而丢更新；跨进程/跨连接池的并发版本见 PG 集成测试。
func TestSecurityEventConcurrentSameBucketCounts(t *testing.T) {
	db := newSecurityEventTestDB(t)
	now := time.Date(2026, time.September, 19, 12, 0, 0, 0, time.UTC)
	service := NewSecurityEventService(db, "secret", func() time.Time { return now })

	const total = 40
	errs := make(chan error, total)
	for i := 0; i < total; i++ {
		go func(i int) {
			errs <- service.Record(SecurityEventInput{
				EventType: "password_reset_spray", Severity: models.SecuritySeverityHigh,
				Route: "/api/password/email/code", Method: "POST", ClientIP: "203.0.113.77",
				TargetType: "email", TargetValue: fmt.Sprintf("t%d@example.com", i%4),
				Blocked: i%3 == 0,
			})
		}(i)
	}

	success := 0
	for i := 0; i < total; i++ {
		if err := <-errs; err == nil {
			success++
		}
	}
	// 统计跨 4 个目标桶聚合：只校验每条事件的计数不丢（同一 target 共享一个桶）。
	var events []models.SecurityEvent
	require.NoError(t, db.Find(&events).Error)
	require.NotEmpty(t, events)

	var attemptSum, blockedSum int
	for _, event := range events {
		attemptSum += event.AttemptCount
		blockedSum += event.BlockedCount
	}
	require.Equal(t, success, attemptSum, "并发写入不得丢失 attempt 计数")
	require.LessOrEqual(t, blockedSum, attemptSum)
}
