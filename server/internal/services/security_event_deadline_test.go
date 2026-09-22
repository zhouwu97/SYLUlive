package services

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// adjustableClock 是可推进的测试时钟：限频窗口要靠推进时间来验证「过窗后还会再报一次」。
type adjustableClock struct {
	mu  sync.Mutex
	now time.Time
}

func newAdjustableClock(start time.Time) *adjustableClock {
	return &adjustableClock{now: start}
}

func (c *adjustableClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *adjustableClock) Advance(by time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(by)
}

// endedByDeadline 判断写入是否因 context 超时而结束。
// GORM 会把驱动层错误和自身错误拼成多错误（"context deadline exceeded; sql: ..."），
// 单靠 errors.Is 认不出来，因此同时匹配错误文本；真实成因另由观察器的取消计数佐证。
func endedByDeadline(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	return strings.Contains(err.Error(), context.DeadlineExceeded.Error())
}

// stalledWriteObserver 记录「写入被卡住」这段模拟里发生的事，
// 用来把预算语义变成可断言的事实：进入了几次、是否被取消、还有没有在飞。
type stalledWriteObserver struct {
	mu          sync.Mutex
	attempts    int
	inflight    int
	maxInflight int
	canceled    int
	timedOut    int
	maxWait     time.Duration
	release     chan struct{}
}

func newStalledWriteObserver() *stalledWriteObserver {
	return &stalledWriteObserver{maxWait: 6 * time.Second, release: make(chan struct{})}
}

func (o *stalledWriteObserver) snapshot() (attempts, inflight, canceled, timedOut int) {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.attempts, o.inflight, o.canceled, o.timedOut
}

// stallSecurityWrites 把 Create 换成「一直等 context」的替身：
// 真实数据库在本地测试里不会悬挂，而 A10 要验证的正是「数据库不返回时我们多久放弃」。
// 回调只在 ctx 结束或 maxWait 到期时返回，因此内部预算没生效时调用方会明显变慢。
func stallSecurityWrites(t *testing.T, db *gorm.DB, o *stalledWriteObserver) {
	t.Helper()
	replace := func(name string, handler func(d *gorm.DB)) {
		if err := db.Callback().Create().Replace(name, handler); err != nil {
			t.Fatalf("注册 %s 替身失败: %v", name, err)
		}
	}
	replace("gorm:create", func(d *gorm.DB) {
		o.mu.Lock()
		o.attempts++
		o.inflight++
		if o.inflight > o.maxInflight {
			o.maxInflight = o.inflight
		}
		o.mu.Unlock()
		defer func() {
			o.mu.Lock()
			o.inflight--
			o.mu.Unlock()
		}()

		var ctx context.Context
		if d.Statement != nil && d.Statement.Context != nil {
			ctx = d.Statement.Context
		}
		if ctx == nil {
			d.AddError(errors.New("替身写入没有拿到 context"))
			o.mu.Lock()
			o.timedOut++
			o.mu.Unlock()
			return
		}
		select {
		case <-ctx.Done():
			o.mu.Lock()
			o.canceled++
			o.mu.Unlock()
			d.AddError(ctx.Err())
		case <-time.After(o.maxWait):
			o.mu.Lock()
			o.timedOut++
			o.mu.Unlock()
			d.AddError(errors.New("写入在测试上限内仍未结束"))
		}
	})
}

func newStalledSecurityService(t *testing.T, now func() time.Time) (*SecurityEventService, *gorm.DB, *stalledWriteObserver) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开测试库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}, &models.SecurityBlock{}); err != nil {
		t.Fatalf("迁移失败: %v", err)
	}
	observer := newStalledWriteObserver()
	stallSecurityWrites(t, db, observer)
	return NewSecurityEventService(db, "test-secret", now), db, observer
}

func securityWriteInput(route string) SecurityEventInput {
	return SecurityEventInput{
		EventType: "login_bruteforce", Severity: "high",
		Route: route, Method: "POST", ClientIP: "203.0.113.9",
		TargetType: "account", TargetValue: "student@example.com",
	}
}

// captureSecurityLogs 把标准库日志重定向到缓冲区。测试串行执行，结束后必须还原。
func captureSecurityLogs(t *testing.T) *bytes.Buffer {
	t.Helper()
	buf := &bytes.Buffer{}
	previousOutput := log.Writer()
	previousFlags := log.Flags()
	log.SetOutput(buf)
	log.SetFlags(0)
	t.Cleanup(func() {
		log.SetOutput(previousOutput)
		log.SetFlags(previousFlags)
	})
	return buf
}

func countDegradedLogLines(buf *bytes.Buffer) int {
	total := 0
	for _, line := range strings.Split(buf.String(), "\n") {
		if strings.Contains(line, "security event write failed") {
			total++
		}
	}
	return total
}

// SEC-01：无 deadline 与 30s 父 deadline 两种上下文里，事件写入都必须被收紧到内部预算。
// HEAD 只在「父 context 没有 deadline」时才加超时，长 deadline 会原样传下去。
func TestSecurityEventWriteBoundedByInternalBudget(t *testing.T) {
	cases := []struct {
		name   string
		parent func() (context.Context, context.CancelFunc)
	}{
		{"no_deadline", func() (context.Context, context.CancelFunc) {
			return context.Background(), func() {}
		}},
		{"long_parent_deadline", func() (context.Context, context.CancelFunc) {
			return context.WithTimeout(context.Background(), 30*time.Second)
		}},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			service, _, observer := newStalledSecurityService(t, nil)
			parent, cancelParent := tc.parent()
			defer cancelParent()

			start := time.Now()
			err := service.RecordContext(parent, securityWriteInput("/api/login"))
			elapsed := time.Since(start)

			if err == nil {
				t.Fatalf("写入被卡住时不能报成功")
			}
			if !endedByDeadline(err) {
				t.Fatalf("应因内部预算超时结束，实际错误: %v", err)
			}
			if elapsed > 4*time.Second {
				t.Fatalf("事件写入耗时 %v，超过内部预算 %v，父 deadline 没有被收紧", elapsed, securityAuditTimeout)
			}
			attempts, inflight, canceled, timedOut := observer.snapshot()
			if attempts != 1 {
				t.Fatalf("一次事件写入应只尝试一次，实际 %d 次", attempts)
			}
			if canceled != 1 || timedOut != 0 {
				t.Fatalf("写入应由内部预算取消（canceled=%d timedOut=%d）", canceled, timedOut)
			}
			if inflight != 0 {
				t.Fatalf("取消后仍有 %d 个写入在飞，连接未归还", inflight)
			}
			if snapshot := service.EventWriteHealth(); snapshot.Status() != SecurityLayerDegraded {
				t.Fatalf("写入失败必须反映为 degraded，实际 %q", snapshot.Status())
			}
		})
	}
}

// SEC-02：父 deadline 比内部预算更早时，必须按父 deadline 结束，不能「为了保底」而延长它。
func TestSecurityEventWriteDoesNotExtendShortParentDeadline(t *testing.T) {
	service, _, observer := newStalledSecurityService(t, nil)
	parent, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	start := time.Now()
	err := service.RecordContext(parent, securityWriteInput("/api/login"))
	elapsed := time.Since(start)

	if !endedByDeadline(err) {
		t.Fatalf("应沿用父 deadline 报错，实际错误: %v", err)
	}
	if elapsed >= securityAuditTimeout {
		t.Fatalf("父 deadline 被延长：耗时 %v，预算 %v", elapsed, securityAuditTimeout)
	}
	if _, _, canceled, timedOut := observer.snapshot(); canceled != 1 || timedOut != 0 {
		t.Fatalf("应由父 deadline 取消（canceled=%d timedOut=%d）", canceled, timedOut)
	}
}

// SEC-04 之一：封禁查询已有 2s 预算，不能被这次改动放宽或去掉。
func TestBlockedLookupStillBounded(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开测试库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}, &models.SecurityBlock{}); err != nil {
		t.Fatalf("迁移失败: %v", err)
	}
	var attempts, canceled int
	var mu sync.Mutex
	stall := func(d *gorm.DB) {
		mu.Lock()
		attempts++
		mu.Unlock()
		ctx := context.Background()
		if d.Statement != nil && d.Statement.Context != nil {
			ctx = d.Statement.Context
		}
		select {
		case <-ctx.Done():
			mu.Lock()
			canceled++
			mu.Unlock()
			d.AddError(ctx.Err())
		case <-time.After(6 * time.Second):
			d.AddError(errors.New("封禁查询在测试上限内仍未结束"))
		}
	}
	if err := db.Callback().Query().Replace("gorm:query", stall); err != nil {
		t.Fatalf("注册查询替身失败: %v", err)
	}
	if err := db.Callback().Row().Replace("gorm:row", stall); err != nil {
		t.Fatalf("注册行查询替身失败: %v", err)
	}
	service := NewSecurityEventService(db, "test-secret", nil)

	parent, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	start := time.Now()
	blocked, err := service.IsBlockedContext(parent, "203.0.113.9", "/api/login")
	elapsed := time.Since(start)
	if err == nil {
		t.Fatalf("封禁查询被卡住时不能报成功")
	}
	if blocked {
		t.Fatalf("查询失败时不得凭空判定已封禁")
	}
	if elapsed > 4*time.Second {
		t.Fatalf("封禁查询耗时 %v，超过内部预算 %v", elapsed, securityAuditTimeout)
	}
	mu.Lock()
	defer mu.Unlock()
	if canceled == 0 {
		t.Fatalf("封禁查询未被内部预算取消，预算语义已丢失")
	}
}

// SEC-04 之二：写失败要能被看到，但不能每次失败都刷屏，也不能再经由同一个故障写入器递归记录失败。
func TestSecurityEventWriteFailureLogIsThrottledAndNotRecursive(t *testing.T) {
	clock := newAdjustableClock(time.Date(2026, 9, 21, 8, 0, 0, 0, time.UTC))
	service, _, observer := newStalledSecurityService(t, clock.Now)
	logs := captureSecurityLogs(t)

	for i := 0; i < 20; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		_ = service.RecordContext(ctx, securityWriteInput(fmt.Sprintf("/api/login")))
		cancel()
	}

	attempts, inflight, _, _ := observer.snapshot()
	if attempts != 20 {
		t.Fatalf("20 次事件写入应产生 20 次数据库尝试，实际 %d 次（疑似失败路径递归写入）", attempts)
	}
	if inflight != 0 {
		t.Fatalf("仍有 %d 个写入在飞", inflight)
	}
	if lines := countDegradedLogLines(logs); lines != 1 {
		t.Fatalf("同一故障窗口内降级日志应只出现一次，实际 %d 次:\n%s", lines, logs.String())
	}

	// 过了限频窗口后必须还能再报一次，否则降级会被第一条日志永久掩盖。
	clock.Advance(2 * time.Minute)
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	_ = service.RecordContext(ctx, securityWriteInput("/api/login"))
	cancel()
	if lines := countDegradedLogLines(logs); lines != 2 {
		t.Fatalf("超过限频窗口后应再次告警，实际 %d 次:\n%s", lines, logs.String())
	}

	snapshot := service.EventWriteHealth()
	if snapshot.Status() == SecurityLayerReady {
		t.Fatalf("连续写失败后健康度不得仍是 ready")
	}
	if snapshot.TotalFailures < 20 {
		t.Fatalf("健康度累计失败数应至少 20，实际 %d", snapshot.TotalFailures)
	}
}
