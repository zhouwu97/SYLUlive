package services

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"html"
	"log"
	"mime"
	"net"
	"net/smtp"
	"net/textproto"
	"strings"
	"sync"
	"time"

	"shenliyuan/internal/models"
)

const (
	// SecurityAlertCooldown 是同一事件类型的最小告警间隔。
	// 五分钟聚合桶本身就会持续累加同一波攻击，不做冷却的话每个桶一封邮件，
	// 管理员会在几分钟内被告警淹没，真正的高危反而被划走。
	SecurityAlertCooldown = 12 * time.Minute
	// SecurityAlertHourlyBudget 是每小时告警邮件上限。超出的事件只累计不外发：
	// 告警渠道自己被刷爆，等于又回到「没人知道」。
	SecurityAlertHourlyBudget = 12
	securityAlertSendTimeout  = 15 * time.Second
	securityAlertQueueSize    = 64
	securityAlertMaxAttempts  = 3
	securityAlertRetryDelay   = 100 * time.Millisecond
)

// ErrSecurityAlertNotConfigured 表示缺少收件人或 SMTP 配置，告警外发未启用。
var ErrSecurityAlertNotConfigured = errors.New("安全告警邮件未配置")

// SecurityAlertEvent 是一次待外发的高危安全事件摘要。
//
// 只带已脱敏字段：告警邮件会离开服务器，不能把原始账号、IP 或令牌带出去。
type SecurityAlertEvent struct {
	EventType    string
	Severity     string
	Status       string
	Route        string
	Method       string
	TargetMasked string
	Action       string
	RequestID    string
	OccurredAt   time.Time
}

// SecurityAlertMailer 投递安全告警邮件，测试可替换为替身。
type SecurityAlertMailer interface {
	SendSecurityAlert(ctx context.Context, to []string, subject, body string) error
}

type configuredSecurityAlertMailer interface {
	Configured() bool
}

// SecurityAlertService 把「高危 + 待处置 + 仍处于 active」的安全事件推到管理员邮箱。
//
// 它补的是安全中心缺的最后一环：事件采集、风险聚合、后台处置和临时阻断都已可用，
// 但管理员不打开后台就可能不知道出现了高危事件。刻意保持最小——去重、冷却、一封邮件，
// 不做 SIEM、不做升级链路、不引入消息队列。规模到需要那些的时候再换实现，
// 这一层的入口（[SecurityAlertService.Record]）不需要跟着改。
//
// 并发与故障语义：判定同步完成（冷却与额度必须立刻生效，否则一次攻击会排队发出多封），
// 真正的 SMTP 发送在后台 goroutine 里做，慢 SMTP 不占用请求路径。发送失败只记录到
// 运行态健康快照并打一条限频日志，绝不回调事件采集——那会把一次邮件故障放大成写入风暴。
type SecurityAlertService struct {
	mailer       SecurityAlertMailer
	recipients   []string
	now          func() time.Time
	cooldown     time.Duration
	hourlyBudget int
	sendTimeout  time.Duration

	delivery *SecurityHealthLayer

	mu          sync.Mutex
	lastByType  map[string]time.Time
	windowStart time.Time
	windowSent  int
	suppressed  int64
	enqueued    int64

	pending chan SecurityAlertEvent

	logMu       sync.Mutex
	lastFailLog time.Time
}

// NewSecurityAlertService 构造告警服务并启动投递 worker。
//
// recipients 为空表示未启用外发：安全中心会如实显示 not_configured，
// 而不是把「没人被通知」伪装成正常。
func NewSecurityAlertService(mailer SecurityAlertMailer, recipients []string, now func() time.Time) *SecurityAlertService {
	if now == nil {
		now = time.Now
	}
	clean := make([]string, 0, len(recipients))
	seen := make(map[string]struct{}, len(recipients))
	for _, recipient := range recipients {
		recipient = strings.TrimSpace(recipient)
		if recipient == "" {
			continue
		}
		lower := strings.ToLower(recipient)
		if _, duplicated := seen[lower]; duplicated {
			continue
		}
		seen[lower] = struct{}{}
		clean = append(clean, recipient)
	}
	service := &SecurityAlertService{
		mailer:       mailer,
		recipients:   clean,
		now:          now,
		cooldown:     SecurityAlertCooldown,
		hourlyBudget: SecurityAlertHourlyBudget,
		sendTimeout:  securityAlertSendTimeout,
		delivery:     newSecurityHealthLayer(now),
		lastByType:   make(map[string]time.Time),
		pending:      make(chan SecurityAlertEvent, securityAlertQueueSize),
	}
	go service.worker()
	return service
}

// Configured 表示收件人与发信通道是否齐备。
func (a *SecurityAlertService) Configured() bool {
	if a == nil || a.mailer == nil || len(a.recipients) == 0 {
		return false
	}
	if configured, ok := a.mailer.(configuredSecurityAlertMailer); ok {
		return configured.Configured()
	}
	return true
}

// DeliveryState 返回告警投递的运行态快照，与其它防护层共用一套词汇。
func (a *SecurityAlertService) DeliveryState() (bool, string, string, map[string]interface{}) {
	if a == nil || a.mailer == nil || len(a.recipients) == 0 {
		return false, SecurityLayerNotConfigured, "recipients_not_configured", nil
	}
	if configured, ok := a.mailer.(configuredSecurityAlertMailer); ok && !configured.Configured() {
		return false, SecurityLayerNotConfigured, "mailer_not_configured", nil
	}
	snapshot := a.delivery.snapshot()
	a.mu.Lock()
	detail := snapshot.Detail()
	detail["recipients"] = len(a.recipients)
	detail["cooldown_minutes"] = int(a.cooldown / time.Minute)
	detail["hourly_budget"] = a.hourlyBudget
	detail["suppressed_total"] = a.suppressed
	detail["enqueued_total"] = a.enqueued
	a.mu.Unlock()
	runtime := snapshot.Status()
	reason := ""
	if runtime == SecurityLayerUnknown {
		// 进程启动后还没有高危事件触发过外发：这既不是成功也不是失败。
		reason = "no_alert_dispatched_yet"
	}
	return true, runtime, reason, detail
}

// Record 评估一次高危安全事件是否需要外发告警。
//
// 命中冷却或额度时静默累计并立刻返回，绝不阻塞调用方；队列满同样直接丢弃——
// 告警不能反过来拖住安全事件采集本身。
func (a *SecurityAlertService) Record(event SecurityAlertEvent) {
	if !a.Configured() || !securityAlertWorthy(event) {
		return
	}
	if strings.TrimSpace(event.EventType) == "" {
		return
	}
	a.mu.Lock()
	now := a.now().UTC()
	cooldownKey := securityAlertCooldownKey(event)
	if last, ok := a.lastByType[cooldownKey]; ok && now.Sub(last) < a.cooldown {
		a.suppressed++
		a.mu.Unlock()
		return
	}
	if a.windowStart.IsZero() || now.Sub(a.windowStart) >= time.Hour {
		a.windowStart, a.windowSent = now, 0
	}
	if a.windowSent >= a.hourlyBudget {
		a.suppressed++
		a.mu.Unlock()
		return
	}
	a.lastByType[cooldownKey] = now
	a.windowSent++
	a.enqueued++
	a.mu.Unlock()

	select {
	case a.pending <- event:
	default:
		a.mu.Lock()
		a.suppressed++
		a.enqueued--
		a.mu.Unlock()
		a.noteDeliveryFailure(errors.New("安全告警队列已满"))
	}
}

func (a *SecurityAlertService) worker() {
	for event := range a.pending {
		var err error
		failureRecorded := false
		for attempt := 1; attempt <= securityAlertMaxAttempts; attempt++ {
			ctx, cancel := context.WithTimeout(context.Background(), a.sendTimeout)
			err = a.mailer.SendSecurityAlert(ctx, a.recipients, securityAlertSubject(event), securityAlertBody(event))
			cancel()
			if err == nil {
				break
			}
			if !failureRecorded {
				a.delivery.recordFailure()
				failureRecorded = true
			}
			if attempt < securityAlertMaxAttempts && securityAlertRetryable(err) {
				time.Sleep(securityAlertRetryDelay)
			} else {
				break
			}
		}
		if err != nil {
			a.noteDeliveryFailure(err)
			continue
		}
		a.delivery.recordSuccess()
	}
}

func securityAlertCooldownKey(event SecurityAlertEvent) string {
	// 严重程度升级必须绕过普通高危事件的冷却窗口，避免升级通知被吞掉。
	return strings.TrimSpace(event.EventType) + "|" + strings.TrimSpace(event.Severity)
}

// noteDeliveryFailure 只打限频日志。
//
// 失败已经证明邮件通道不可靠，再往安全事件表里写一条「告警失败」既可能继续失败，
// 也可能把告警故障伪装成一次攻击事件。运行态计数由 delivery 承担。
func (a *SecurityAlertService) noteDeliveryFailure(err error) {
	now := a.now().UTC()
	a.logMu.Lock()
	if !a.lastFailLog.IsZero() && now.Sub(a.lastFailLog) < securityEventWriteFailureLogInterval {
		a.logMu.Unlock()
		return
	}
	a.lastFailLog = now
	a.logMu.Unlock()
	log.Printf("ERROR security alert delivery failed, 告警外发已降级（每 %s 最多一条）: %v",
		securityEventWriteFailureLogInterval, err)
}

// securityAlertWorthy 决定哪些事件值得把人叫醒。
//
// 只有「高危/严重」且「仍需管理员处置」才外发：审计流水（正常验证码、正常改密、
// 已生效的封禁计数）自己会安静地躺在后台，把它们也发出去等于把邮箱变成第二个日志。
func securityAlertWorthy(event SecurityAlertEvent) bool {
	if event.Severity != models.SecuritySeverityHigh && event.Severity != models.SecuritySeverityCritical {
		return false
	}
	if event.Status != models.SecurityEventStatusActive {
		return false
	}
	return models.SecurityEventActionable(event.EventType)
}

// SMTPSecurityAlertMailer 用既有 SMTP 配置发送告警邮件。
//
// 与验证码邮件共用一份配置，但接口独立：告警是给管理员的运维通道，
// 不该和面向用户的验证码发送逻辑耦合在一起。
type SMTPSecurityAlertMailer struct {
	config SMTPConfig
}

// NewSMTPSecurityAlertMailer 构造走 SMTP 的告警发信实现。
func NewSMTPSecurityAlertMailer(config SMTPConfig) *SMTPSecurityAlertMailer {
	return &SMTPSecurityAlertMailer{config: config}
}

func (m *SMTPSecurityAlertMailer) Configured() bool {
	return m != nil && strings.TrimSpace(m.config.Host) != "" &&
		strings.TrimSpace(m.config.User) != "" && strings.TrimSpace(m.config.Pass) != "" &&
		strings.TrimSpace(m.config.From) != ""
}

func (m *SMTPSecurityAlertMailer) SendSecurityAlert(ctx context.Context, to []string, subject, body string) error {
	if !m.Configured() {
		return ErrSecurityAlertNotConfigured
	}
	if len(to) == 0 {
		return ErrSecurityAlertNotConfigured
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	port := strings.TrimSpace(m.config.Port)
	if port == "" {
		port = "587"
	}
	subject = mime.QEncoding.Encode("UTF-8", subject)
	message := []byte("From: " + m.config.From + "\r\n" +
		"To: " + strings.Join(to, ",") + "\r\n" +
		"Subject: " + subject + "\r\n" +
		"MIME-Version: 1.0\r\n" +
		"Content-Type: text/html; charset=UTF-8\r\n\r\n" + body)
	auth := smtp.PlainAuth("", m.config.User, m.config.Pass, m.config.Host)
	addr := net.JoinHostPort(m.config.Host, port)
	// 每次 SMTP 操作都复用同一条带 deadline 的连接；smtp.SendMail 不接收 context，
	// 在外层另起 goroutine 等待会让超时后的底层发送继续挂住。
	dialer := net.Dialer{Timeout: securityAlertSendTimeout}
	conn, err := dialer.DialContext(ctx, "tcp", addr)
	if err != nil {
		return err
	}
	defer conn.Close()
	deadline := time.Now().Add(securityAlertSendTimeout)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	if err := conn.SetDeadline(deadline); err != nil {
		return err
	}
	stopCancel := context.AfterFunc(ctx, func() { _ = conn.SetDeadline(time.Now()) })
	defer stopCancel()

	client, err := smtp.NewClient(conn, m.config.Host)
	if err != nil {
		return err
	}
	defer client.Close()
	if ok, _ := client.Extension("STARTTLS"); ok {
		if err := client.StartTLS(&tls.Config{ServerName: m.config.Host, MinVersion: tls.VersionTLS12}); err != nil {
			return err
		}
	}
	if err := client.Auth(auth); err != nil {
		return err
	}
	if err := client.Mail(m.config.From); err != nil {
		return err
	}
	for _, recipient := range to {
		if err := client.Rcpt(recipient); err != nil {
			return err
		}
	}
	writer, err := client.Data()
	if err != nil {
		return err
	}
	if _, err := writer.Write(message); err != nil {
		_ = writer.Close()
		return err
	}
	if err := writer.Close(); err != nil {
		return err
	}
	// DATA 结束后的 250 已确认邮件进入 SMTP 队列；QUIT 只是会话收尾，
	// 收尾断开不能撤销已接收的正文，否则上层重试会制造重复告警。
	_ = client.Quit()
	return nil
}

// securityAlertRetryable 区分明确的永久拒绝与网络/临时故障。
// textproto.Error 是 net/smtp 对 4xx/5xx 响应的统一表示，未知错误保留重试，
// 以覆盖连接被中途断开的场景。
func securityAlertRetryable(err error) bool {
	var smtpErr *textproto.Error
	if errors.As(err, &smtpErr) {
		return smtpErr.Code >= 400 && smtpErr.Code < 500
	}
	return true
}

func securityAlertSubject(event SecurityAlertEvent) string {
	severity := event.Severity
	if severity == "" {
		severity = models.SecuritySeverityHigh
	}
	return fmt.Sprintf("[沈理校园安全告警][%s] %s", strings.ToUpper(severity), event.EventType)
}

func securityAlertBody(event SecurityAlertEvent) string {
	occurred := event.OccurredAt
	if occurred.IsZero() {
		occurred = time.Now()
	}
	line := func(label, value string) string {
		value = strings.TrimSpace(value)
		if value == "" {
			value = "—"
		}
		return "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">" + html.EscapeString(label) +
			"</td><td style=\"padding:4px 0;\"><code>" + html.EscapeString(value) + "</code></td></tr>"
	}
	return "<!doctype html><html lang=\"zh-CN\"><body style=\"font-family:Arial,'PingFang SC','Microsoft YaHei',sans-serif;line-height:1.6;color:#222;\">" +
		"<h2 style=\"margin:0 0 12px;\">安全告警：需要人工确认</h2>" +
		"<p style=\"margin:0 0 12px;color:#666;\">检测到高危安全事件。以下内容已脱敏，请登录管理后台「安全中心」核实并处置。</p>" +
		"<table style=\"border-collapse:collapse;\">" +
		line("事件类型", event.EventType) +
		line("严重等级", event.Severity) +
		line("处置动作", event.Action) +
		line("路由", event.Method+" "+event.Route) +
		line("目标（脱敏）", event.TargetMasked) +
		line("请求编号", event.RequestID) +
		line("发生时间（UTC）", occurred.UTC().Format(time.RFC3339)) +
		"</table>" +
		"<p style=\"margin:16px 0 0;color:#666;\">同一事件类型在冷却期内不会重复打扰；本邮件不包含账号、IP 或凭据原文。</p>" +
		"</body></html>"
}
