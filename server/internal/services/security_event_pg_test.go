//go:build integration

// SEC-04：安全事件写入在真实 PostgreSQL、多个独立连接池并发下的行为。
//
// 计划 10.4 对本用例给出两条**不同**的断言，必须分别验证，不能混在同一个场景里：
//
//	(a) 不同来源并发记录 —— 不因一把无必要全局锁互堵；
//	(b) 同桶并发 UPSERT  —— 计数准确。
//
// 这两条在同一个用例里是互相矛盾的：把所有写入强制到同一个 bucket_key，
// 它们在数据库行锁上**必然**串行（这正是 (b) 计数准确的前提），
// 于是根本观察不到 (a) 想证明的"没有进程内全局串行"。
// 因此这里拆成两个用例，各自针对一条断言。
//
// 运行方式：
//
//	TEST_DATABASE_DSN=postgres://... ALLOW_DESTRUCTIVE_INTEGRATION_TESTS=1 \
//	  go test -tags=integration ./internal/services -run 'TestSecurityEvent'
//
// 注意：这两个用例只覆盖"同进程内不存在不必要的全局串行"与"聚合计数不丢更新"，
// 不构成抗压/容量结论。容量观察见各用例内的日志输出。
package services

import (
	"context"
	"io"
	"log"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"shenliyuan/internal/models"
)

func openSecurityEventPG(t *testing.T, maxOpenConns int) *gorm.DB {
	t.Helper()
	dsn := strings.TrimSpace(os.Getenv("TEST_DATABASE_DSN"))
	if dsn == "" {
		t.Skip("TEST_DATABASE_DSN 未设置，跳过 PostgreSQL 安全事件并发集成测试")
	}
	// 只保留真正的 SQL 错误：并发场景下 SLOW SQL 日志会淹没真正的失败原因。
	quiet := logger.New(log.New(io.Discard, "", 0), logger.Config{
		SlowThreshold:             0,
		LogLevel:                  logger.Error,
		IgnoreRecordNotFoundError: true,
	})
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{Logger: quiet})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(maxOpenConns)

	if os.Getenv("ALLOW_DESTRUCTIVE_INTEGRATION_TESTS") != "1" {
		t.Skip("ALLOW_DESTRUCTIVE_INTEGRATION_TESTS 未显式开启，跳过破坏性集成测试")
	}
	var dbName string
	require.NoError(t, db.Raw("SELECT current_database()").Scan(&dbName).Error)
	require.True(t, strings.HasSuffix(strings.ToLower(dbName), "_test"),
		"拒绝在非 *_test 数据库上执行破坏性集成测试：%s", dbName)
	return db
}

// SEC-04(a)：不同来源（不同 bucket_key）并发写入不得因为进程内全局串行而互堵。
//
// 判定方式刻意不依赖墙钟时间，避免在负载波动的机器上变成 flaky 用例：
// 在每个写入协程真正进入数据库写入路径时打一个"同时在场"栅栏，
// 直接统计**同时在场的写入协程数峰值**。
//
//   - 若实现里仍有一把覆盖 UPSERT 的全局 mutex，同时在场数恒为 1，栅栏永远等不到全部写入者，
//     maxInFlight 只会是 1，用例以明确信息失败（而不是挂死）。
//   - 去掉该 mutex 后，不同 bucket 的写入可以真正并行到达数据库，同时在场数必然 >= 2。
//
// 为什么必须用不同来源：写成同一个 bucket 时，PostgreSQL 行锁本身就会把它们排成队，
// 那时同时在场数为 1 属于**正确行为**，不能用来判定存在多余全局锁。
func TestSecurityEventDistinctBucketsDoNotSerializeOnInProcessLock(t *testing.T) {
	// 连接数必须 >= 并发数，否则栅栏会让等待连接的协程拿不到连接而超时。
	const writers = 16
	const barrierWait = 5 * time.Second

	db := openSecurityEventPG(t, writers)
	require.NoError(t, db.AutoMigrate(&models.SecurityEvent{}, &models.SecurityBlock{}))
	require.NoError(t, db.Exec("TRUNCATE security_events, security_blocks RESTART IDENTITY CASCADE").Error)

	var (
		inFlight       int64
		maxInFlight    int64
		arrived        int64
		barrierAborted int64
	)
	barrierReached := make(chan struct{})
	var closeOnce sync.Once

	db.Callback().Create().Before("gorm:create").Register("test:security_event_inflight", func(tx *gorm.DB) {
		current := atomic.AddInt64(&inFlight, 1)
		for {
			previous := atomic.LoadInt64(&maxInFlight)
			if current <= previous || atomic.CompareAndSwapInt64(&maxInFlight, previous, current) {
				break
			}
		}
		defer func() {
			if atomic.AddInt64(&arrived, 1) == writers {
				closeOnce.Do(func() { close(barrierReached) })
			}
			select {
			case <-barrierReached:
			case <-time.After(barrierWait):
				// 等不到全部写入者：说明确有全局串行。解除其余等待者，避免用例挂死，
				// 由断言给出可读的失败原因。
				atomic.StoreInt64(&barrierAborted, 1)
				closeOnce.Do(func() { close(barrierReached) })
			}
		}()
	})
	db.Callback().Create().After("gorm:create").Register("test:security_event_inflight_end", func(tx *gorm.DB) {
		atomic.AddInt64(&inFlight, -1)
	})

	now := time.Date(2026, time.September, 19, 12, 0, 0, 0, time.UTC)
	service := NewSecurityEventService(db, "pg-secret", func() time.Time { return now })

	var wg sync.WaitGroup
	errs := make([]error, writers)
	started := make(chan struct{})
	for i := 0; i < writers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-started // 尽量让所有协程同时出发
			errs[i] = service.Record(SecurityEventInput{
				EventType: "password_reset_spray", Severity: models.SecuritySeverityHigh,
				Route: "/api/password/email/code", Method: "POST",
				// 每个写入者一个独立来源，因而 bucket_key 互不相同。
				ClientIP:   "203.0.113." + itoa(i+1),
				TargetType: "email", TargetValue: "shared-target@example.com",
			})
		}(i)
	}
	wallStart := time.Now()
	close(started)
	wg.Wait()
	wall := time.Since(wallStart)

	// 先断言"是否存在不必要的进程内全局串行"，再断言单次调用是否报错。
	// 顺序很关键：若有人把全局锁加回来，其他写入者会被挡在写入路径之外，
	// 队列尾部的调用会先因等待超时而报错；若先断言 err，失败信息会指向"超时"，
	// 掩盖真正的原因。这里让诊断断言先给出结论。
	observed := atomic.LoadInt64(&maxInFlight)
	require.Zero(t, atomic.LoadInt64(&barrierAborted),
		"存在写入者无法同时进入写入路径：疑似仍有一把覆盖 UPSERT 的全局锁（同时在场的峰值仅为 %d）",
		observed)
	require.GreaterOrEqual(t, observed, int64(2),
		"不同来源的并发写入必须能同时在数据库写入路径中，实际同时在场峰值=%d", observed)

	for i, err := range errs {
		require.NoError(t, err, "并发写入不应报错（第 %d 个）", i)
	}

	var rows int64
	require.NoError(t, db.Model(&models.SecurityEvent{}).Count(&rows).Error)
	require.EqualValues(t, writers, rows, "不同来源应各自落一行，不能被合并到同一个桶")

	// 容量观察（不作为断言）：仅记录并发数/耗时/数据库条件，供报告如实引用。
	t.Logf("容量观察：并发=%d 不同 bucket 耗时=%v 同时在场峰值=%d 连接数=%d 数据库=PostgreSQL",
		writers, wall, observed, writers)
}

// SEC-04(b)：同桶并发 UPSERT 必须计数准确，不丢更新。
//
// 前置说明——为什么这里显式给出比默认值更长的 context 预算：
// 本用例刻意把所有写入压进**同一个五分钟桶**，所以它们在 bucket_key 唯一索引对应的行锁上
// 必然串行，这正是计数准确的前提。每次持锁时间包含一次事务提交（fsync），
// 本机（Windows 开发机）实测单次约 45ms，20 次以上的队列尾部会因为"排队等待"而非"出错"
// 触发 securityAuditTimeout（2 秒）被 context 取消，从而把断言对象从"计数是否准确"
// 偏成"本机磁盘有多快"。这里用显式预算把断言重新聚焦到 SEC-04(b) 的契约本身。
// "写入等待必须有界"由 security_event_hardening_test.go 的 TestSecurityEventBoundedByContext 覆盖。
func TestSecurityEventConcurrentPoolsKeepCountsAccurate(t *testing.T) {
	const perPool = 10

	primary := openSecurityEventPG(t, 8)
	secondary := openSecurityEventPG(t, 8)
	require.NoError(t, primary.AutoMigrate(&models.SecurityEvent{}, &models.SecurityBlock{}))
	require.NoError(t, primary.Exec("TRUNCATE security_events, security_blocks RESTART IDENTITY CASCADE").Error)

	now := time.Date(2026, time.September, 19, 12, 0, 0, 0, time.UTC)
	services := []*SecurityEventService{
		NewSecurityEventService(primary, "pg-secret", func() time.Time { return now }),
		NewSecurityEventService(secondary, "pg-secret", func() time.Time { return now }),
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	var wg sync.WaitGroup
	errs := make(chan error, perPool*len(services))
	blocked := 0
	for poolIndex, svc := range services {
		for i := 0; i < perPool; i++ {
			isBlocked := (poolIndex+i)%5 == 0
			if isBlocked {
				blocked++
			}
			wg.Add(1)
			go func(svc *SecurityEventService, isBlocked bool) {
				defer wg.Done()
				errs <- svc.RecordContext(ctx, SecurityEventInput{
					EventType: "password_reset_spray", Severity: models.SecuritySeverityHigh,
					Route: "/api/password/email/code", Method: "POST", ClientIP: "203.0.113.42",
					TargetType: "email", TargetValue: "shared-target@example.com",
					Blocked: isBlocked,
				})
			}(svc, isBlocked)
		}
	}
	wallStart := time.Now()
	wg.Wait()
	wall := time.Since(wallStart)
	close(errs)

	success := 0
	for err := range errs {
		require.NoError(t, err, "同桶并发写入不应报错")
		success++
	}

	var events []models.SecurityEvent
	require.NoError(t, primary.Find(&events).Error)
	require.Len(t, events, 1, "同桶事件必须聚合为一条")

	var attemptSum, blockedSum int
	for _, event := range events {
		attemptSum += event.AttemptCount
		blockedSum += event.BlockedCount
	}
	require.Equal(t, success, attemptSum, "跨连接池并发下 attempt_count 不能丢更新")
	require.EqualValues(t, blocked, blockedSum, "跨连接池并发下 blocked_count 不能丢更新")

	t.Logf("容量观察：并发=%d（2 个连接池 × %d）同桶耗时=%v 连接数/池=8 数据库=PostgreSQL",
		perPool*len(services), perPool, wall)
}

func itoa(value int) string {
	if value == 0 {
		return "0"
	}
	var buf [8]byte
	position := len(buf)
	for value > 0 {
		position--
		buf[position] = byte('0' + value%10)
		value /= 10
	}
	return string(buf[position:])
}
