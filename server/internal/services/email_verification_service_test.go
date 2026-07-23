package services

import (
	"errors"
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

func (m *capturedVerificationMailer) SendVerificationCode(email string, purpose string, code string) error {
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
	if err := db.AutoMigrate(&models.EmailVerificationChallenge{}); err != nil {
		t.Fatalf("迁移验证码表失败: %v", err)
	}
	mailer := &capturedVerificationMailer{}
	service := NewEmailVerificationService(db, mailer, "test-ip-secret", func() time.Time { return *now })
	return service, mailer, db
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
