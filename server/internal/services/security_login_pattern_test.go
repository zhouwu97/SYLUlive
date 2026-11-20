package services

import (
	"context"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

func TestSecurityLoginPatternRequiresVolumeAndMultipleTargets(t *testing.T) {
	for _, p := range []LoginFailurePattern{{1, 1}, {20, 20}, {20, 99}, {19, 100}, {1, 10000}} {
		require.False(t, p.NeedsReview(), "%+v", p)
	}
	require.True(t, (LoginFailurePattern{20, 100}).NeedsReview())
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	t.Cleanup(func() { _ = sqlDB.Close() })
	require.NoError(t, db.AutoMigrate(&models.SecurityEvent{}))
	now := time.Now().UTC()
	service := NewSecurityEventService(db, "pattern-test", func() time.Time { return now })
	ip := "203.0.113.50"
	for i, item := range []struct {
		kind, source, target string
		count                int
		first                time.Time
	}{
		{"login_failed", ip, "a", 5, now},
		{"login_failed", ip, "b", 6, now},
		{"login_bruteforce", ip, "c", 10000, now},
		{"login_failed", "203.0.113.51", "d", 100, now},
		{"login_failed", ip, "e", 100, now.Add(-11 * time.Minute)},
	} {
		require.NoError(t, db.Create(&models.SecurityEvent{BucketKey: string(rune('a' + i)), EventType: item.kind,
			Severity: "low", Status: "active", Route: "/api/login", Method: "POST", Action: "observed",
			SourceIPHash: service.Hash(item.source), SourceAttributionValid: true, TargetHash: service.Hash(item.target),
			AttemptCount: item.count, FirstSeenAt: item.first, LastSeenAt: now}).Error)
	}
	pattern, err := service.LoginFailurePatternContext(context.Background(), ip, now.Add(-10*time.Minute))
	require.NoError(t, err)
	require.EqualValues(t, 2, pattern.DistinctTargets)
	require.EqualValues(t, 11, pattern.FailedAttempts, "冷却重试、其他来源和跨区间旧桶不能充当失败证据")
	localPattern, err := service.LoginFailurePatternContext(context.Background(), ip, now.Add(-10*time.Minute).In(time.FixedZone("test-local", 8*3600)))
	require.NoError(t, err)
	require.Equal(t, pattern, localPattern, "相同瞬间的本地时区不能改变检测结果")
	pattern, err = service.LoginFailurePatternContext(context.Background(), "", now.Add(-10*time.Minute))
	require.NoError(t, err)
	require.Zero(t, pattern.FailedAttempts)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = service.LoginFailurePatternContext(ctx, ip, now.Add(-10*time.Minute))
	require.ErrorIs(t, err, context.Canceled)
}
