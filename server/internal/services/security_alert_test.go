package services

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type recordedAlert struct {
	to      []string
	subject string
	body    string
}

type recordingAlertMailer struct {
	mu   sync.Mutex
	sent []recordedAlert
	err  error
}

func (m *recordingAlertMailer) SendSecurityAlert(_ context.Context, to []string, subject, body string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sent = append(m.sent, recordedAlert{
		to:      append([]string(nil), to...),
		subject: subject,
		body:    body,
	})
	return m.err
}

func (m *recordingAlertMailer) alerts() []recordedAlert {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]recordedAlert(nil), m.sent...)
}

// waitForAlerts 等待后台投递 worker 追上判定结果。
// Record 的冷却是同步的，真正发信是异步的：用轮询而不是固定睡眠，
// 用例就不会因为调度抖动时红时绿。
func waitForAlerts(t *testing.T, mailer *recordingAlertMailer, want int) []recordedAlert {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		got := mailer.alerts()
		if len(got) >= want {
			return got
		}
		if time.Now().After(deadline) {
			t.Fatalf("等待 %d 封告警超时，实际 %d 封", want, len(got))
		}
		time.Sleep(2 * time.Millisecond)
	}
}

type fakeAlertClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *fakeAlertClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeAlertClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

func newTestAlertService(t *testing.T, mailer SecurityAlertMailer, recipients ...string) (*SecurityAlertService, *fakeAlertClock) {
	t.Helper()
	clock := &fakeAlertClock{now: time.Date(2026, 9, 22, 8, 0, 0, 0, time.UTC)}
	return NewSecurityAlertService(mailer, recipients, clock.Now), clock
}

func highAlert(eventType string) SecurityAlertEvent {
	return SecurityAlertEvent{
		EventType:    eventType,
		Severity:     models.SecuritySeverityHigh,
		Status:       models.SecurityEventStatusActive,
		Route:        "/api/login",
		Method:       "POST",
		TargetMasked: "s***@example.com",
		Action:       "throttled",
		RequestID:    "req-1",
		OccurredAt:   time.Date(2026, 9, 22, 8, 0, 0, 0, time.UTC),
	}
}

// 高危且待处置的事件必须把人叫醒，并且只带脱敏信息。
func TestSecurityAlertNotifiesHighActionableEvent(t *testing.T) {
	mailer := &recordingAlertMailer{}
	alerts, _ := newTestAlertService(t, mailer, "ops@example.com", "ops@example.com", " oncall@example.com ")
	alerts.Record(highAlert("login_password_spray"))

	sent := waitForAlerts(t, mailer, 1)
	if len(sent[0].to) != 2 {
		t.Fatalf("收件人应去重并清理空白: %v", sent[0].to)
	}
	if sent[0].to[0] != "ops@example.com" || sent[0].to[1] != "oncall@example.com" {
		t.Fatalf("收件人 = %v", sent[0].to)
	}
	if !strings.Contains(sent[0].subject, "login_password_spray") {
		t.Fatalf("主题缺少事件类型: %q", sent[0].subject)
	}
	if !strings.Contains(sent[0].body, "s***@example.com") {
		t.Fatalf("正文缺少脱敏目标: %q", sent[0].body)
	}
	if !strings.Contains(sent[0].body, "POST /api/login") {
		t.Fatalf("正文缺少路由: %q", sent[0].body)
	}
	configured, runtime, _, _ := alerts.DeliveryState()
	if !configured || runtime != SecurityLayerReady {
		t.Fatalf("投递成功后应为 ready: configured=%v runtime=%s", configured, runtime)
	}
}

// 冷却期内同一事件类型只发一封：五分钟聚合桶会持续累加同一波攻击，
// 不做冷却的话管理员几分钟内就被淹没，真正的高危反而被划走。
func TestSecurityAlertSuppressesRepeatWithinCooldown(t *testing.T) {
	mailer := &recordingAlertMailer{}
	alerts, clock := newTestAlertService(t, mailer, "ops@example.com")

	for i := 0; i < 5; i++ {
		alerts.Record(highAlert("login_password_spray"))
		clock.Advance(time.Minute)
	}
	waitForAlerts(t, mailer, 1)
	time.Sleep(20 * time.Millisecond)
	if got := mailer.alerts(); len(got) != 1 {
		t.Fatalf("冷却期内不应重复发信: %d 封", len(got))
	}

	// 冷却期过后同一类型重新出现，必须再叫一次人。
	clock.Advance(SecurityAlertCooldown)
	alerts.Record(highAlert("login_password_spray"))
	waitForAlerts(t, mailer, 2)
}

// 不同事件类型是新信息，不能被上一类的冷却一起吃掉。
func TestSecurityAlertNotifiesDistinctEventTypes(t *testing.T) {
	mailer := &recordingAlertMailer{}
	alerts, _ := newTestAlertService(t, mailer, "ops@example.com")
	alerts.Record(highAlert("login_password_spray"))
	alerts.Record(highAlert("credential_change_anomaly"))
	waitForAlerts(t, mailer, 2)
}

// 审计流水和中低危事件不值得把人叫醒：把它们也发出去等于把邮箱变成第二个日志。
func TestSecurityAlertIgnoresAuditAndLowSeverity(t *testing.T) {
	mailer := &recordingAlertMailer{}
	alerts, _ := newTestAlertService(t, mailer, "ops@example.com")

	audit := highAlert("login_failed")
	alerts.Record(audit)
	alerts.Record(highAlert("security_blocked_request"))
	alerts.Record(highAlert("verification_activity"))

	low := highAlert("login_password_spray")
	low.Severity = models.SecuritySeverityMedium
	alerts.Record(low)
	low.Severity = models.SecuritySeverityLow
	alerts.Record(low)
	resolved := highAlert("login_password_spray")
	resolved.Status = models.SecurityEventStatusResolved
	alerts.Record(resolved)

	waitForNoAlerts(t, mailer)
	if !securityAlertWorthy(highAlert("login_password_spray")) {
		t.Fatal("高危待处置事件必须判定为值得告警")
	}
	if securityAlertWorthy(audit) {
		t.Fatal("审计流水不得判定为值得告警")
	}
	if securityAlertWorthy(resolved) {
		t.Fatal("已处置事件不得再次触发告警")
	}
}

func waitForNoAlerts(t *testing.T, mailer *recordingAlertMailer) {
	t.Helper()
	// 给后台 worker 一个真实的调度机会，再去断言「一封都没发」。
	time.Sleep(20 * time.Millisecond)
	if got := mailer.alerts(); len(got) != 0 {
		t.Fatalf("不应外发告警，实际 %d 封", len(got))
	}
}

// 每小时额度兜底：告警渠道自己被刷爆，等于又回到没人知道。
func TestSecurityAlertRespectsHourlyBudget(t *testing.T) {
	mailer := &recordingAlertMailer{}
	alerts, clock := newTestAlertService(t, mailer, "ops@example.com")
	alerts.hourlyBudget = 2

	// 三类事件挤在同一小时内（间隔只有冷却期），第三类必须被额度挡下。
	for _, eventType := range []string{"a_high", "b_high", "c_high"} {
		alerts.Record(highAlert(eventType))
		clock.Advance(SecurityAlertCooldown)
	}
	waitForAlerts(t, mailer, 2)
	time.Sleep(20 * time.Millisecond)
	if got := mailer.alerts(); len(got) != 2 {
		t.Fatalf("超过每小时额度仍在发信: %d 封", len(got))
	}

	// 新的一小时预算必须恢复，否则一次攻击会让当天余下的告警全部失效。
	clock.Advance(time.Hour)
	alerts.Record(highAlert("d_high"))
	waitForAlerts(t, mailer, 3)
}

// 没配收件人就是没配，不能报成正常。安全中心据此显示 not_configured。
func TestSecurityAlertStateWhenUnconfigured(t *testing.T) {
	mailer := &recordingAlertMailer{}
	alerts, _ := newTestAlertService(t, mailer)
	if alerts.Configured() {
		t.Fatal("没有收件人时不得判定为已配置")
	}
	alerts.Record(highAlert("login_password_spray"))
	waitForNoAlerts(t, mailer)

	configured, runtime, reason, _ := alerts.DeliveryState()
	if configured || runtime != SecurityLayerNotConfigured {
		t.Fatalf("configured=%v runtime=%s", configured, runtime)
	}
	if reason != "recipients_not_configured" {
		t.Fatalf("reason = %q", reason)
	}

	var detached *SecurityAlertService
	configured, runtime, reason, _ = detached.DeliveryState()
	if configured || runtime != SecurityLayerNotConfigured {
		t.Fatalf("未接入时也必须如实上报: configured=%v runtime=%s reason=%s", configured, runtime, reason)
	}
	detached.Record(highAlert("login_password_spray"))
}

// 邮件通道故障只降级告警这一层，绝不能反过来把一次真实攻击的采集结果搞成失败。
func TestSecurityAlertDeliveryFailureIsDegradedNotFatal(t *testing.T) {
	mailer := &recordingAlertMailer{err: errors.New("smtp down")}
	alerts, _ := newTestAlertService(t, mailer, "ops@example.com")
	alerts.Record(highAlert("login_password_spray"))
	waitForAlerts(t, mailer, 1)

	_, runtime, _, detail := alerts.DeliveryState()
	if runtime != SecurityLayerDegraded {
		t.Fatalf("投递失败后应为 degraded，实际 %s", runtime)
	}
	if detail["consecutive_failures"] != 1 {
		t.Fatalf("失败计数 = %v", detail["consecutive_failures"])
	}

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}); err != nil {
		t.Fatal(err)
	}
	events := NewSecurityEventService(db, "security-alert-test", time.Now)
	events.SetAlertService(alerts)
	if err := events.RecordContext(context.Background(), SecurityEventInput{
		EventType: "login_password_spray", Severity: models.SecuritySeverityHigh,
		Route: "/api/login", Method: "POST", TargetMasked: "s***@example.com",
	}); err != nil {
		t.Fatalf("告警失败不得影响事件采集: %v", err)
	}
	if state := events.EventWriteHealth().Status(); state != SecurityLayerReady {
		t.Fatalf("事件采集运行态 = %s，期望 ready", state)
	}
}

// 事件落账之后才叫人：反过来「先发邮件再写库」会让一次数据库故障变成没人能查证的空告警。
func TestSecurityEventServiceDispatchesAlertForRecordedHighEvent(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}); err != nil {
		t.Fatal(err)
	}
	mailer := &recordingAlertMailer{}
	alerts, _ := newTestAlertService(t, mailer, "ops@example.com")
	events := NewSecurityEventService(db, "security-alert-test", time.Now)
	events.SetAlertService(alerts)

	if err := events.RecordContext(context.Background(), SecurityEventInput{
		EventType: "credential_change_anomaly", Severity: models.SecuritySeverityCritical,
		Route: "/api/change_password", Method: "POST",
		TargetValue: "raw-secret@example.com", TargetMasked: "r***@example.com",
		Action: "blocked", RequestID: "req-42",
	}); err != nil {
		t.Fatal(err)
	}
	sent := waitForAlerts(t, mailer, 1)
	if strings.Contains(sent[0].body, "raw-secret@example.com") {
		t.Fatal("告警邮件不得携带未脱敏目标")
	}
	if !strings.Contains(sent[0].body, "r***@example.com") || !strings.Contains(sent[0].body, "req-42") {
		t.Fatalf("告警邮件缺少定位信息: %q", sent[0].body)
	}
	if !strings.Contains(strings.ToUpper(sent[0].subject), "CRITICAL") {
		t.Fatalf("主题缺少严重等级: %q", sent[0].subject)
	}

	// 未接入告警通道时采集必须照常工作。
	detached := NewSecurityEventService(db, "security-alert-test", time.Now)
	if err := detached.RecordContext(context.Background(), SecurityEventInput{
		EventType: "login_password_spray", Severity: models.SecuritySeverityHigh,
	}); err != nil {
		t.Fatal(err)
	}
	configured, runtime, reason, _ := detached.AlertDeliveryState()
	if configured || runtime != SecurityLayerNotConfigured || reason != "alert_service_not_wired" {
		t.Fatalf("configured=%v runtime=%s reason=%s", configured, runtime, reason)
	}
}
