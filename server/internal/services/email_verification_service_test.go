package services

import (
	"bufio"
	"context"
	"errors"
	"net"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type capturedVerificationMailer struct {
	codes map[string]string
}

func (m *capturedVerificationMailer) SendVerificationCode(_ context.Context, email string, purpose string, code string) error {
	if m.codes == nil {
		m.codes = make(map[string]string)
	}
	m.codes[email+":"+purpose] = code
	return nil
}

func newEmailVerificationTestService(t *testing.T, now *time.Time) (*EmailVerificationService, *capturedVerificationMailer, *gorm.DB) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.EmailVerificationChallenge{}, &models.EmailVerificationRequest{}, &models.VerificationAttemptBucket{}, &models.VerificationAttempt{}, &models.SecurityEvent{}); err != nil {
		t.Fatalf("迁移验证码表失败: %v", err)
	}
	mailer := &capturedVerificationMailer{}
	service := NewEmailVerificationService(db, mailer, "test-ip-secret", func() time.Time { return *now })
	return service, mailer, db
}

func TestEmailVerificationLimitsAreSharedAcrossPurposes(t *testing.T) {
	now := time.Date(2026, time.July, 22, 12, 0, 0, 0, time.UTC)
	service, _, _ := newEmailVerificationTestService(t, &now)
	const email = "shared@example.com"
	if err := service.Request(email, models.EmailVerificationPurposeRegister, nil, "127.0.0.1"); err != nil {
		t.Fatalf("首次请求失败: %v", err)
	}
	if err := service.Request(email, models.EmailVerificationPurposeResetPassword, nil, "127.0.0.1"); !errors.Is(err, ErrSendTooFrequently) {
		t.Fatalf("切换用途不应绕过 60 秒目标限制，错误=%v", err)
	}
	now = now.Add(61 * time.Second)
	if err := service.Request(email, models.EmailVerificationPurposeResetPassword, nil, "127.0.0.1"); err != nil {
		t.Fatalf("冷却结束后请求失败: %v", err)
	}
}

func TestEmailVerificationConsumesCodeAndIsolatesPurpose(t *testing.T) {
	now := time.Date(2026, time.July, 22, 12, 0, 0, 0, time.UTC)
	service, mailer, db := newEmailVerificationTestService(t, &now)
	email := "User@Example.COM"
	if err := service.Request(email, models.EmailVerificationPurposeRegister, nil, "127.0.0.1"); err != nil {
		t.Fatalf("请求验证码失败: %v", err)
	}
	code := mailer.codes["user@example.com:register"]
	if len(code) != 6 {
		t.Fatalf("验证码=%q，期望六位数字", code)
	}
	var challenge models.EmailVerificationChallenge
	if err := db.First(&challenge).Error; err != nil {
		t.Fatalf("读取验证码记录失败: %v", err)
	}
	if strings.Contains(challenge.CodeHash, code) {
		t.Fatal("验证码明文不应写入数据库")
	}
	if err := service.Validate(email, models.EmailVerificationPurposeResetPassword, code, true); !errors.Is(err, ErrCodeNotFound) {
		t.Fatalf("跨用途验证码错误=%v，期望=%v", err, ErrCodeNotFound)
	}
	if err := service.Validate(email, models.EmailVerificationPurposeRegister, code, true); err != nil {
		t.Fatalf("消费正确验证码失败: %v", err)
	}
	if err := service.Validate(email, models.EmailVerificationPurposeRegister, code, true); !errors.Is(err, ErrCodeNotFound) {
		t.Fatalf("重复消费验证码错误=%v，期望=%v", err, ErrCodeNotFound)
	}
}

func TestEmailVerificationLimitsAttemptsAndExpires(t *testing.T) {
	now := time.Date(2026, time.July, 22, 12, 0, 0, 0, time.UTC)
	service, _, _ := newEmailVerificationTestService(t, &now)
	if err := service.Request("attempts@example.com", models.EmailVerificationPurposeRegister, nil, "127.0.0.1"); err != nil {
		t.Fatalf("请求验证码失败: %v", err)
	}
	for attempt := 0; attempt < 5; attempt++ {
		if err := service.Validate("attempts@example.com", models.EmailVerificationPurposeRegister, "000000", false); !errors.Is(err, ErrCodeInvalid) {
			t.Fatalf("第 %d 次错误验证码结果=%v，期望=%v", attempt+1, err, ErrCodeInvalid)
		}
	}
	if err := service.Validate("attempts@example.com", models.EmailVerificationPurposeRegister, "000000", false); !errors.Is(err, ErrCodeAttempts) {
		t.Fatalf("超出次数错误=%v，期望=%v", err, ErrCodeAttempts)
	}

	if err := service.Request("expired@example.com", models.EmailVerificationPurposeRegister, nil, "127.0.0.2"); err != nil {
		t.Fatalf("请求过期测试验证码失败: %v", err)
	}
	now = now.Add(11 * time.Minute)
	if err := service.Validate("expired@example.com", models.EmailVerificationPurposeRegister, "000000", false); !errors.Is(err, ErrCodeExpired) {
		t.Fatalf("过期验证码错误=%v，期望=%v", err, ErrCodeExpired)
	}
}

func TestUseValidatedChallengeConsumesOnlyAfterBusinessCommit(t *testing.T) {
	now := time.Date(2026, time.July, 22, 12, 0, 0, 0, time.UTC)
	service, mailer, _ := newEmailVerificationTestService(t, &now)
	const email = "atomic@example.com"
	if err := service.Request(email, models.EmailVerificationPurposeRegister, nil, "127.0.0.3"); err != nil {
		t.Fatalf("请求验证码失败: %v", err)
	}
	code := mailer.codes[email+":"+models.EmailVerificationPurposeRegister]
	callbackErr := errors.New("模拟账户写入失败")
	if err := service.UseValidatedChallenge(email, models.EmailVerificationPurposeRegister, code, func(tx *gorm.DB, _ models.EmailVerificationChallenge) error {
		return callbackErr
	}); !errors.Is(err, callbackErr) {
		t.Fatalf("业务失败错误=%v，期望=%v", err, callbackErr)
	}
	if err := service.Validate(email, models.EmailVerificationPurposeRegister, code, true); err != nil {
		t.Fatalf("业务失败后验证码应仍可使用: %v", err)
	}
}

func TestVerificationFailureUsesCurrentRequestSourceAndRollingWindow(t *testing.T) {
	now := time.Date(2026, time.July, 22, 12, 10, 1, 0, time.UTC)
	service, mailer, db := newEmailVerificationTestService(t, &now)
	security := NewSecurityEventService(db, "security-test-secret", func() time.Time { return now })
	service.SetSecurityEventService(security)
	const email = "rolling@example.com"
	if err := service.Request(email, models.EmailVerificationPurposeRegister, nil, "203.0.113.10"); err != nil {
		t.Fatalf("请求验证码失败: %v", err)
	}
	for i := 0; i < 19; i++ {
		if err := db.Create(&models.VerificationAttempt{
			TargetHash: service.hashValue(email), SourceHash: service.hashIP("203.0.113.11"),
			Purpose: models.EmailVerificationPurposeRegister, CreatedAt: now.Add(-2 * time.Second),
		}).Error; err != nil {
			t.Fatalf("写入历史失败尝试失败: %v", err)
		}
	}
	if err := service.ValidateWithClientIP(email, models.EmailVerificationPurposeRegister, "000000", false, "203.0.113.11"); !errors.Is(err, ErrCodeAttempts) {
		t.Fatalf("滚动窗口未计入边界内失败尝试: %v", err)
	}
	var latest models.VerificationAttempt
	if err := db.Order("id DESC").First(&latest).Error; err != nil {
		t.Fatalf("读取当前失败尝试失败: %v", err)
	}
	if latest.SourceHash != security.Hash("203.0.113.11") || latest.SourceHash == security.Hash("203.0.113.10") {
		t.Fatalf("验证码失败来源未使用当前请求来源: %+v", latest)
	}
	_ = mailer
}

func TestVerificationMailDispatcherTimesOutBlockedMailer(t *testing.T) {
	mailer := &blockingVerificationMailer{}
	dispatcher := newVerificationMailDispatcher(mailer, 1, 1, 10*time.Millisecond)
	failed := make(chan struct{}, 1)
	if err := dispatcher.Dispatch("timeout@example.com", models.EmailVerificationPurposeRegister, "123456", func(err error) {
		if !errors.Is(err, ErrVerificationMailTimeout) {
			t.Errorf("超时错误=%v，期望=%v", err, ErrVerificationMailTimeout)
		}
		failed <- struct{}{}
	}, nil); err != nil {
		t.Fatalf("投递任务不应因入队失败: %v", err)
	}
	select {
	case <-failed:
	case <-time.After(time.Second):
		t.Fatal("邮件发送超时后未触发失败回调")
	}
}

func TestSMTPVerificationMailerTreatsDataAcceptedAsSuccessWhenQuitFails(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("启动 SMTP 测试监听失败: %v", err)
	}
	defer listener.Close()

	serverDone := make(chan error, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr != nil {
			serverDone <- acceptErr
			return
		}
		defer conn.Close()

		reader := bufio.NewReader(conn)
		writer := bufio.NewWriter(conn)
		writeResponse := func(response string) error {
			if _, err := writer.WriteString(response + "\r\n"); err != nil {
				return err
			}
			return writer.Flush()
		}
		readCommand := func() (string, error) {
			line, err := reader.ReadString('\n')
			return strings.TrimSpace(line), err
		}
		expectPrefix := func(prefix string) error {
			line, err := readCommand()
			if err != nil {
				return err
			}
			if !strings.HasPrefix(strings.ToUpper(line), prefix) {
				return errors.New("unexpected SMTP command: " + line)
			}
			return nil
		}

		if err := writeResponse("220 test.smtp ESMTP"); err != nil {
			serverDone <- err
			return
		}
		if err := expectPrefix("EHLO"); err != nil {
			serverDone <- err
			return
		}
		if _, err := writer.WriteString("250-test.smtp\r\n250 AUTH PLAIN\r\n"); err != nil {
			serverDone <- err
			return
		}
		if err := writer.Flush(); err != nil {
			serverDone <- err
			return
		}
		if err := expectPrefix("AUTH PLAIN"); err != nil {
			serverDone <- err
			return
		}
		if err := writeResponse("235 2.7.0 Authentication successful"); err != nil {
			serverDone <- err
			return
		}
		for _, response := range []string{"MAIL FROM:", "RCPT TO:"} {
			if err := expectPrefix(response); err != nil {
				serverDone <- err
				return
			}
			if err := writeResponse("250 2.0.0 OK"); err != nil {
				serverDone <- err
				return
			}
		}
		if err := expectPrefix("DATA"); err != nil {
			serverDone <- err
			return
		}
		if err := writeResponse("354 End data with <CR><LF>.<CR><LF>"); err != nil {
			serverDone <- err
			return
		}
		for {
			line, err := readCommand()
			if err != nil {
				serverDone <- err
				return
			}
			if line == "." {
				break
			}
		}
		if err := writeResponse("250 2.0.0 queued"); err != nil {
			serverDone <- err
			return
		}
		if err := expectPrefix("QUIT"); err != nil {
			serverDone <- err
			return
		}
		// 模拟 SMTP 服务端已接受 DATA，但在 QUIT 阶段直接断开连接。
		serverDone <- nil
	}()

	mailer := NewSMTPVerificationMailer(SMTPConfig{
		Host: "127.0.0.1", Port: strconv.Itoa(listener.Addr().(*net.TCPAddr).Port),
		User: "user", Pass: "pass", From: "from@example.com",
		AllowInsecure: true,
	})
	err = mailer.SendVerificationCode(context.Background(), "to@example.com", models.EmailVerificationPurposeRegister, "123456")
	if err != nil {
		t.Fatalf("DATA 已被 SMTP 服务端接受时，QUIT 失败不应判定投递失败: %v", err)
	}
	select {
	case serverErr := <-serverDone:
		if serverErr != nil {
			t.Fatalf("SMTP 测试服务端交互失败: %v", serverErr)
		}
	case <-time.After(time.Second):
		t.Fatal("SMTP 测试服务端未完成交互")
	}
}

func TestSMTPVerificationMailerHonorsConnectionDeadline(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("启动 SMTP 测试监听失败: %v", err)
	}
	defer listener.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			accepted <- conn
		}
	}()

	mailer := NewSMTPVerificationMailer(SMTPConfig{
		Host: "127.0.0.1", Port: strconv.Itoa(listener.Addr().(*net.TCPAddr).Port),
		User: "user", Pass: "pass", From: "from@example.com",
		AllowInsecure: true,
	})
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	started := time.Now()
	err = mailer.SendVerificationCode(ctx, "to@example.com", models.EmailVerificationPurposeRegister, "123456")
	if err == nil {
		t.Fatal("SMTP greeting 未返回时应因连接 deadline 失败")
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("SMTP deadline 未及时生效，耗时=%v", elapsed)
	}
	select {
	case conn := <-accepted:
		_ = conn.Close()
	default:
	}
}

type blockingVerificationMailer struct{}

func (*blockingVerificationMailer) SendVerificationCode(ctx context.Context, _ string, _ string, _ string) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(time.Second):
		return nil
	}
}
