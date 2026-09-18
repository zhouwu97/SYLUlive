package services

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math/big"
	"mime"
	"net"
	"net/smtp"
	"regexp"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

const emailVerificationCodeTTL = 10 * time.Minute

// 验证码目标冷却统一为 60 秒，所有公开/登录后验证码入口共用这一窗口。
const emailVerificationRequestCooldown = 60 * time.Second

var emailPattern = regexp.MustCompile(`^[^@\s]{1,64}@[^@\s]{1,255}$`)

var (
	ErrEmailInvalid      = errors.New("邮箱格式无效")
	ErrCodeNotFound      = errors.New("验证码不存在或已失效")
	ErrCodeExpired       = errors.New("验证码已过期")
	ErrCodeAttempts      = errors.New("验证码尝试次数过多")
	ErrCodeInvalid       = errors.New("验证码错误")
	ErrSendTooFrequently = errors.New("请 60 秒后再发送验证码")
	ErrEmailRateLimited  = errors.New("该邮箱发送验证码过于频繁")
	ErrIPRateLimited     = errors.New("该网络发送验证码过于频繁")
	ErrTargetHourlyLimit = errors.New("该邮箱已达到每小时验证码上限")
	ErrTargetDailyLimit  = errors.New("该邮箱已达到每日验证码上限")
	ErrSourceRateLimited = errors.New("该业务来源发送验证码过于频繁")
	ErrSourceSprayLimit  = errors.New("该来源正在批量请求验证码，请稍后再试")
	ErrVerificationSpray = ErrSourceSprayLimit
	ErrPurposeInvalid    = errors.New("验证码用途无效")
	ErrMailNotConfigured = errors.New("服务器未配置邮件服务")
)

// VerificationRateLimitError 保留稳定业务错误的同时携带服务端计算出的等待秒数。
type VerificationRateLimitError struct {
	Cause      error
	RetryAfter time.Duration
}

func (e *VerificationRateLimitError) Error() string { return e.Cause.Error() }
func (e *VerificationRateLimitError) Unwrap() error { return e.Cause }

func verificationRateLimitError(cause error, retryAfter time.Duration) error {
	if retryAfter < time.Second {
		retryAfter = time.Second
	}
	return &VerificationRateLimitError{Cause: cause, RetryAfter: retryAfter}
}

// SMTPConfig 是通用邮件服务配置。
type SMTPConfig struct {
	Host string
	Port string
	User string
	Pass string
	From string
}

// VerificationMailer 允许测试替换邮件发送实现。
type VerificationMailer interface {
	SendVerificationCode(ctx context.Context, email string, purpose string, code string) error
}

// SMTPVerificationMailer 使用已有 SMTP 配置发送验证码邮件。
type SMTPVerificationMailer struct {
	config SMTPConfig
}

func NewSMTPVerificationMailer(config SMTPConfig) *SMTPVerificationMailer {
	return &SMTPVerificationMailer{config: config}
}

func (m *SMTPVerificationMailer) SendVerificationCode(ctx context.Context, email string, purpose string, code string) error {
	if strings.TrimSpace(m.config.Host) == "" || strings.TrimSpace(m.config.User) == "" || strings.TrimSpace(m.config.Pass) == "" || strings.TrimSpace(m.config.From) == "" {
		return ErrMailNotConfigured
	}
	if ctx == nil {
		ctx = context.Background()
	}
	port := strings.TrimSpace(m.config.Port)
	if port == "" {
		port = "587"
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	conn, err := (&net.Dialer{}).DialContext(ctx, "tcp", net.JoinHostPort(m.config.Host, port))
	if err != nil {
		return err
	}
	defer conn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		if err := conn.SetDeadline(deadline); err != nil {
			return err
		}
	}
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
	if err := client.Auth(smtp.PlainAuth("", m.config.User, m.config.Pass, m.config.Host)); err != nil {
		return err
	}
	if err := client.Mail(m.config.From); err != nil {
		return err
	}
	if err := client.Rcpt(email); err != nil {
		return err
	}
	writer, err := client.Data()
	if err != nil {
		return err
	}
	if _, err := io.Copy(writer, strings.NewReader(string(buildVerificationEmail(email, m.config.From, purpose, code)))); err != nil {
		_ = writer.Close()
		return err
	}
	if err := writer.Close(); err != nil {
		return err
	}
	return client.Quit()
}

func buildVerificationEmail(to string, from string, purpose string, code string) []byte {
	title := map[string]string{
		models.EmailVerificationPurposeRegister:      "沈理校园注册验证码",
		models.EmailVerificationPurposeBind:          "沈理校园绑定邮箱验证码",
		models.EmailVerificationPurposeChange:        "沈理校园修改邮箱验证码",
		models.EmailVerificationPurposeResetPassword: "沈理校园密码重置验证码",
	}[purpose]
	if title == "" {
		title = "沈理校园邮箱验证码"
	}
	body := fmt.Sprintf("%s\n\n验证码：%s\n有效期：10 分钟\n\n如果不是本人操作，请忽略此邮件。\n", title, code)
	return []byte("To: " + to + "\r\n" +
		"From: " + from + "\r\n" +
		"Subject: " + mime.QEncoding.Encode("UTF-8", title) + "\r\n" +
		"MIME-Version: 1.0\r\n" +
		"Content-Type: text/plain; charset=UTF-8\r\n\r\n" + body)
}

// EmailVerificationService 负责验证码创建、限流、校验和一次性消费。
type EmailVerificationService struct {
	db         *gorm.DB
	mailer     VerificationMailer
	ipSecret   []byte
	now        func() time.Time
	security   *SecurityEventService
	dispatcher *VerificationMailDispatcher
}

func NewEmailVerificationService(db *gorm.DB, mailer VerificationMailer, ipSecret string, now func() time.Time) *EmailVerificationService {
	if now == nil {
		now = time.Now
	}
	return &EmailVerificationService{db: db, mailer: mailer, ipSecret: []byte(ipSecret), now: now}
}

// SetSecurityEventService 注入安全中心；保持旧测试/调用方的构造函数兼容。
func (s *EmailVerificationService) SetSecurityEventService(security *SecurityEventService) {
	s.security = security
}

// SetMailDispatcher 启用有界邮件队列；未注入时保留测试与本地调用的同步发送语义。
func (s *EmailVerificationService) SetMailDispatcher(dispatcher *VerificationMailDispatcher) {
	s.dispatcher = dispatcher
}

func NormalizeEmail(input string) (string, error) {
	email := strings.ToLower(strings.TrimSpace(input))
	if len(email) > 320 || !emailPattern.MatchString(email) {
		return "", ErrEmailInvalid
	}
	return email, nil
}

func IsVerificationPurpose(purpose string) bool {
	switch purpose {
	case models.EmailVerificationPurposeRegister,
		models.EmailVerificationPurposeBind,
		models.EmailVerificationPurposeChange,
		models.EmailVerificationPurposeResetPassword:
		return true
	default:
		return false
	}
}

func (s *EmailVerificationService) Request(email string, purpose string, userID *uint, clientIP string) error {
	return s.createAndSend(email, purpose, userID, clientIP)
}

// ReservePublicRequest 为公开验证码接口预留完全一致的限流额度。
// 是否实际发送邮件由调用方在查询账号后决定，不能影响外部响应。
func (s *EmailVerificationService) ReservePublicRequest(email string, purpose string, clientIP string) error {
	if s == nil || s.db == nil || s.mailer == nil {
		return ErrMailNotConfigured
	}
	if !IsVerificationPurpose(purpose) {
		return ErrPurposeInvalid
	}
	normalized, err := NormalizeEmail(email)
	if err != nil {
		return err
	}
	return s.reserveRequest(normalized, purpose, clientIP, true)
}

// SendReservedPublicRequest 为公开接口发送已完成限流预留的验证码。
// 调用方必须保持注册/找回密码的公共响应一致，投递错误由安全事件记录。
func (s *EmailVerificationService) SendReservedPublicRequest(email string, purpose string, userID *uint, clientIP string) error {
	return s.createChallengeAndSend(email, purpose, userID, clientIP)
}

func (s *EmailVerificationService) createAndSend(email string, purpose string, userID *uint, clientIP string) error {
	if s == nil || s.db == nil || s.mailer == nil {
		return ErrMailNotConfigured
	}
	if !IsVerificationPurpose(purpose) {
		return ErrPurposeInvalid
	}
	normalized, err := NormalizeEmail(email)
	if err != nil {
		return err
	}
	if err := s.reserveRequest(normalized, purpose, clientIP, false); err != nil {
		return err
	}
	return s.createChallengeAndSend(normalized, purpose, userID, clientIP)
}

func (s *EmailVerificationService) createChallengeAndSend(email string, purpose string, userID *uint, clientIP string) error {
	if s == nil || s.db == nil || s.mailer == nil {
		return ErrMailNotConfigured
	}
	normalized, err := NormalizeEmail(email)
	if err != nil {
		return err
	}
	now := s.now()
	ipHash := s.hashIP(clientIP)
	code, err := generateEmailVerificationCode()
	if err != nil {
		return err
	}
	codeHash, err := bcrypt.GenerateFromPassword([]byte(code), bcrypt.DefaultCost)
	if err != nil {
		return err
	}

	challenge := models.EmailVerificationChallenge{
		UserID: userID, Email: normalized, Purpose: purpose, CodeHash: string(codeHash),
		ExpiresAt: now.Add(emailVerificationCodeTTL), RequestIPHash: ipHash, CreatedAt: now,
	}
	if err := s.db.Create(&challenge).Error; err != nil {
		return err
	}
	removeChallenge := func() {
		// 邮件发送失败的验证码不能继续有效，用户可立即重新请求。
		_ = s.db.Delete(&models.EmailVerificationChallenge{}, challenge.ID).Error
	}
	if s.dispatcher != nil {
		if err := s.dispatcher.Dispatch(normalized, purpose, code, func(err error) {
			removeChallenge()
			s.recordVerificationMailFailure(normalized, purpose, clientIP, err)
		}, func() {
			s.recordVerificationMail(normalized, purpose, clientIP)
		}); err != nil {
			removeChallenge()
			s.recordVerificationMailFailure(normalized, purpose, clientIP, err)
			return err
		}
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), verificationMailSendTimeout)
	defer cancel()
	err = normalizeVerificationMailError(ctx, s.mailer.SendVerificationCode(ctx, normalized, purpose, code))
	if err != nil {
		removeChallenge()
		s.recordVerificationMailFailure(normalized, purpose, clientIP, err)
		return err
	}
	s.recordVerificationMail(normalized, purpose, clientIP)
	return nil
}

func normalizeVerificationMailError(ctx context.Context, err error) error {
	if err == nil {
		return nil
	}
	if ctx != nil && ctx.Err() != nil {
		return ErrVerificationMailTimeout
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return ErrVerificationMailTimeout
	}
	return err
}

func (s *EmailVerificationService) recordVerificationMail(email, purpose, clientIP string) {
	if s.security == nil {
		return
	}
	eventType := "verification_activity"
	if purpose == models.EmailVerificationPurposeResetPassword {
		eventType = "password_reset_activity"
	}
	_ = s.security.Record(SecurityEventInput{
		EventType: eventType, Severity: models.SecuritySeverityInfo, Route: "email_verification", Method: "SMTP",
		ClientIP: clientIP, TargetType: "email", TargetValue: email, TargetMasked: maskEmailForSecurity(email),
		SkipAttempt: true, MailSent: true, Action: "mail_sent", Metadata: map[string]interface{}{"purpose": purpose},
	})
}

func (s *EmailVerificationService) recordVerificationMailFailure(email, purpose, clientIP string, err error) {
	if s.security == nil {
		return
	}
	_ = s.security.Record(SecurityEventInput{
		EventType: "verification_mail_delivery_failed", Severity: models.SecuritySeverityMedium,
		Route: "email_verification", Method: "SMTP", ClientIP: clientIP,
		TargetType: "email", TargetValue: email, TargetMasked: maskEmailForSecurity(email),
		SkipAttempt: true, Action: "mail_failed", Metadata: map[string]interface{}{
			"purpose": purpose, "reason": err.Error(),
		},
	})
}

// reserveRequest 是所有验证码入口共享的目标/来源账本。public 参数仅保留在接口语义上，
// 账本本身按邮箱、来源和用途统一统计，防止切换 register/reset/send_code 绕过额度。
func (s *EmailVerificationService) reserveRequest(normalized, purpose, clientIP string, public bool) error {
	now := s.now()
	ipHash := s.hashIP(clientIP)
	var reserveErr error
	err := s.db.Transaction(func(tx *gorm.DB) error {
		if tx.Dialector.Name() == "postgres" {
			for _, scope := range []string{"verification-email:" + normalized, "verification-ip:" + ipHash} {
				if err := tx.Exec("SELECT pg_advisory_xact_lock(hashtext(?))", scope).Error; err != nil {
					return err
				}
			}
		}
		var targetHour, targetDay, sourceTenMinutes, sourceHour int64
		var oldestTarget, oldestTargetDay, oldestSourceTenMinutes, oldestSourceHour models.EmailVerificationRequest
		if err := tx.Model(&models.EmailVerificationRequest{}).
			Where("email = ? AND created_at >= ?", normalized, now.Add(-time.Hour)).Count(&targetHour).Error; err != nil {
			return err
		}
		_ = tx.Where("email = ? AND created_at >= ?", normalized, now.Add(-time.Hour)).Order("created_at ASC").First(&oldestTarget).Error
		_ = tx.Where("email = ? AND created_at >= ?", normalized, now.Add(-24*time.Hour)).Order("created_at ASC").First(&oldestTargetDay).Error
		if err := tx.Model(&models.EmailVerificationRequest{}).
			Where("email = ? AND created_at >= ?", normalized, now.Add(-24*time.Hour)).Count(&targetDay).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.EmailVerificationRequest{}).
			Where("request_ip_hash = ? AND purpose = ? AND created_at >= ?", ipHash, purpose, now.Add(-10*time.Minute)).Count(&sourceTenMinutes).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.EmailVerificationRequest{}).
			Where("request_ip_hash = ? AND purpose = ? AND created_at >= ?", ipHash, purpose, now.Add(-time.Hour)).Count(&sourceHour).Error; err != nil {
			return err
		}
		_ = tx.Where("request_ip_hash = ? AND purpose = ? AND created_at >= ?", ipHash, purpose, now.Add(-10*time.Minute)).Order("created_at ASC").First(&oldestSourceTenMinutes).Error
		_ = tx.Where("request_ip_hash = ? AND purpose = ? AND created_at >= ?", ipHash, purpose, now.Add(-time.Hour)).Order("created_at ASC").First(&oldestSourceHour).Error
		var distinctTargets int64
		if err := tx.Model(&models.EmailVerificationRequest{}).
			Where("request_ip_hash = ? AND created_at >= ?", ipHash, now.Add(-10*time.Minute)).
			Distinct("email").Count(&distinctTargets).Error; err != nil {
			return err
		}
		var latest models.EmailVerificationRequest
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("email = ?", normalized).
			Order("created_at DESC").First(&latest).Error
		if err == nil && now.Sub(latest.CreatedAt) < emailVerificationRequestCooldown {
			reserveErr = verificationRateLimitError(ErrSendTooFrequently, emailVerificationRequestCooldown-now.Sub(latest.CreatedAt))
		} else if targetHour >= 3 {
			retryAfter := time.Hour
			if !oldestTarget.CreatedAt.IsZero() {
				retryAfter = time.Hour - now.Sub(oldestTarget.CreatedAt)
			}
			reserveErr = verificationRateLimitError(ErrTargetHourlyLimit, retryAfter)
		} else if targetDay >= 6 {
			retryAfter := 24 * time.Hour
			if !oldestTargetDay.CreatedAt.IsZero() {
				retryAfter = 24*time.Hour - now.Sub(oldestTargetDay.CreatedAt)
			}
			reserveErr = verificationRateLimitError(ErrTargetDailyLimit, retryAfter)
		} else if sourceTenMinutes >= 30 || sourceHour >= 100 {
			retryAfter := time.Hour
			if sourceTenMinutes >= 30 && !oldestSourceTenMinutes.CreatedAt.IsZero() {
				retryAfter = 10*time.Minute - now.Sub(oldestSourceTenMinutes.CreatedAt)
			} else if !oldestSourceHour.CreatedAt.IsZero() {
				retryAfter = time.Hour - now.Sub(oldestSourceHour.CreatedAt)
			}
			reserveErr = verificationRateLimitError(ErrSourceRateLimited, retryAfter)
		} else if distinctTargets >= 8 {
			var sprayTargets []struct {
				Email     string    `gorm:"column:email"`
				FirstSeen time.Time `gorm:"column:first_seen"`
			}
			if err := tx.Model(&models.EmailVerificationRequest{}).
				Select("email, MIN(created_at) AS first_seen").
				Where("request_ip_hash = ? AND created_at >= ?", ipHash, now.Add(-10*time.Minute)).
				Group("email").Order("first_seen ASC").Scan(&sprayTargets).Error; err != nil {
				return err
			}
			retryAfter := 10 * time.Minute
			if len(sprayTargets) >= 8 {
				// 只有降到 7 个不同目标后才会放行，取需要过期的那一个目标的时间。
				index := len(sprayTargets) - 8
				retryAfter = 10*time.Minute - now.Sub(sprayTargets[index].FirstSeen)
			}
			reserveErr = verificationRateLimitError(ErrSourceSprayLimit, retryAfter)
		}
		if reserveErr != nil {
			return nil
		}
		return tx.Create(&models.EmailVerificationRequest{
			Email: normalized, Purpose: purpose, RequestIPHash: ipHash, CreatedAt: now,
		}).Error
	})
	if err != nil {
		return err
	}
	if reserveErr != nil {
		s.recordAbuse(normalized, purpose, clientIP, reserveErr, public)
		return reserveErr
	}
	if s.security != nil {
		eventType := "verification_activity"
		if purpose == models.EmailVerificationPurposeResetPassword {
			eventType = "password_reset_activity"
		}
		_ = s.security.Record(SecurityEventInput{
			EventType: eventType, Severity: models.SecuritySeverityInfo, Route: "email_verification", Method: "POST",
			ClientIP: clientIP, TargetType: "email", TargetValue: normalized, TargetMasked: maskEmailForSecurity(normalized),
			Action: "request_accepted", Metadata: map[string]interface{}{"purpose": purpose},
		})
	}
	return nil
}

func (s *EmailVerificationService) recordAbuse(email, purpose, clientIP string, err error, public bool) {
	if s.security == nil {
		return
	}
	eventType := "verification_cooldown"
	severity := models.SecuritySeverityInfo
	switch {
	case errors.Is(err, ErrTargetHourlyLimit), errors.Is(err, ErrTargetDailyLimit):
		eventType = "email_target_flood"
		severity = models.SecuritySeverityHigh
	case errors.Is(err, ErrSourceRateLimited):
		eventType = "verification_source_rate"
		severity = models.SecuritySeverityMedium
	case errors.Is(err, ErrVerificationSpray):
		eventType = "verification_spray"
		severity = models.SecuritySeverityHigh
		if purpose == models.EmailVerificationPurposeResetPassword {
			eventType = "password_reset_spray"
		}
	}
	_ = s.security.Record(SecurityEventInput{
		EventType: eventType, Severity: severity, Route: "email_verification", Method: "POST",
		ClientIP: clientIP, TargetType: "email", TargetValue: email, TargetMasked: maskEmailForSecurity(email),
		Blocked: true, Action: "throttled", Metadata: map[string]interface{}{
			"purpose": purpose, "reason": err.Error(), "public": public,
		},
	})
}

func maskEmailForSecurity(email string) string {
	at := strings.LastIndex(email, "@")
	if at <= 0 {
		return "***"
	}
	local, domain := email[:at], email[at+1:]
	if len(local) <= 2 {
		return local[:1] + "***@" + domain
	}
	return local[:2] + "***" + local[len(local)-2:] + "@" + domain
}

func (s *EmailVerificationService) Validate(email string, purpose string, code string, consume bool) error {
	return s.ValidateWithClientIP(email, purpose, code, consume, "")
}

// ValidateWithClientIP 使用当前验证码校验请求的来源记录失败尝试。
// clientIP 只在服务内转换为 HMAC 摘要，不会进入数据库。
func (s *EmailVerificationService) ValidateWithClientIP(email string, purpose string, code string, consume bool, clientIP string) error {
	if s == nil || s.db == nil {
		return ErrCodeNotFound
	}
	if !IsVerificationPurpose(purpose) {
		return ErrPurposeInvalid
	}
	normalized, err := NormalizeEmail(email)
	if err != nil {
		return err
	}
	now := s.now()
	var validationErr error
	err = s.db.Transaction(func(tx *gorm.DB) error {
		var challenge models.EmailVerificationChallenge
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("email = ? AND purpose = ? AND consumed_at IS NULL", normalized, purpose).
			Order("created_at DESC").First(&challenge).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			validationErr = ErrCodeNotFound
			return nil
		}
		if err != nil {
			return err
		}
		if now.After(challenge.ExpiresAt) {
			validationErr = ErrCodeExpired
			return nil
		}
		if challenge.Attempts >= 5 {
			validationErr = ErrCodeAttempts
			return nil
		}
		if bcrypt.CompareHashAndPassword([]byte(challenge.CodeHash), []byte(strings.TrimSpace(code))) != nil {
			if err := tx.Model(&challenge).Update("attempts", challenge.Attempts+1).Error; err != nil {
				return err
			}
			exceeded, err := s.recordVerificationFailure(tx, normalized, purpose, challenge.RequestIPHash, clientIP, now)
			if err != nil {
				return err
			}
			// 业务校验失败不能作为事务错误返回，否则尝试次数更新会被回滚。
			if exceeded {
				validationErr = ErrCodeAttempts
			} else {
				validationErr = ErrCodeInvalid
			}
			return nil
		}
		if consume {
			return tx.Model(&challenge).Update("consumed_at", now).Error
		}
		return nil
	})
	if err != nil {
		return err
	}
	return validationErr
}

// UseValidatedChallenge 在同一事务内校验验证码、执行账户写入并消费验证码。
// 回调返回错误时整个事务回滚，验证码仍可用于用户修正业务错误后重试。
func (s *EmailVerificationService) UseValidatedChallenge(
	email string,
	purpose string,
	code string,
	fn func(tx *gorm.DB, challenge models.EmailVerificationChallenge) error,
) error {
	return s.UseValidatedChallengeWithClientIP(email, purpose, code, "", fn)
}

// UseValidatedChallengeWithClientIP 在校验验证码的同时绑定当前请求来源，供改密、注册等业务事务使用。
func (s *EmailVerificationService) UseValidatedChallengeWithClientIP(
	email string,
	purpose string,
	code string,
	clientIP string,
	fn func(tx *gorm.DB, challenge models.EmailVerificationChallenge) error,
) error {
	if s == nil || s.db == nil {
		return ErrCodeNotFound
	}
	if !IsVerificationPurpose(purpose) {
		return ErrPurposeInvalid
	}
	if fn == nil {
		return errors.New("验证码业务处理函数不能为空")
	}

	normalized, err := NormalizeEmail(email)
	if err != nil {
		return err
	}
	now := s.now()
	var validationErr error
	err = s.db.Transaction(func(tx *gorm.DB) error {
		var challenge models.EmailVerificationChallenge
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("email = ? AND purpose = ? AND consumed_at IS NULL", normalized, purpose).
			Order("created_at DESC").First(&challenge).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			validationErr = ErrCodeNotFound
			return nil
		}
		if err != nil {
			return err
		}
		if now.After(challenge.ExpiresAt) {
			validationErr = ErrCodeExpired
			return nil
		}
		if challenge.Attempts >= 5 {
			validationErr = ErrCodeAttempts
			return nil
		}
		if bcrypt.CompareHashAndPassword([]byte(challenge.CodeHash), []byte(strings.TrimSpace(code))) != nil {
			if err := tx.Model(&challenge).Update("attempts", challenge.Attempts+1).Error; err != nil {
				return err
			}
			exceeded, err := s.recordVerificationFailure(tx, normalized, purpose, challenge.RequestIPHash, clientIP, now)
			if err != nil {
				return err
			}
			if exceeded {
				validationErr = ErrCodeAttempts
			} else {
				validationErr = ErrCodeInvalid
			}
			return nil
		}
		if err := fn(tx, challenge); err != nil {
			return err
		}
		return tx.Model(&challenge).Update("consumed_at", now).Error
	})
	if err != nil {
		return err
	}
	return validationErr
}

func (s *EmailVerificationService) recordVerificationFailure(tx *gorm.DB, email, purpose, challengeSourceHash, clientIP string, now time.Time) (bool, error) {
	// 旧版单元测试或滚动迁移期间可能尚未建新表；challenge 自身的五次上限仍然有效，
	// 这里不能因为安全统计表缺失而把正常验证码校验整体打成 500。
	if !tx.Migrator().HasTable(&models.VerificationAttempt{}) {
		return false, nil
	}
	sourceHash := strings.TrimSpace(challengeSourceHash)
	if strings.TrimSpace(clientIP) != "" {
		sourceHash = s.hashIP(clientIP)
	}
	targetHash := s.hashValue(email)
	if err := tx.Create(&models.VerificationAttempt{
		TargetHash: targetHash, SourceHash: sourceHash, Purpose: purpose, CreatedAt: now,
	}).Error; err != nil {
		return false, err
	}
	var targetFailures, sourceFailures int64
	if err := tx.Model(&models.VerificationAttempt{}).
		Where("target_hash = ? AND created_at >= ?", targetHash, now.Add(-10*time.Minute)).
		Count(&targetFailures).Error; err != nil {
		return false, err
	}
	if err := tx.Model(&models.VerificationAttempt{}).
		Where("source_hash = ? AND created_at >= ?", sourceHash, now.Add(-10*time.Minute)).
		Count(&sourceFailures).Error; err != nil {
		return false, err
	}
	if targetFailures >= 20 || sourceFailures >= 50 {
		if s.security != nil {
			_ = s.security.Record(SecurityEventInput{
				EventType: "verification_code_bruteforce", Severity: models.SecuritySeverityHigh,
				Route: "email_verification", Method: "POST", SourceHash: sourceHash, TargetType: "email",
				TargetValue: email, TargetMasked: maskEmailForSecurity(email), Blocked: true,
				Action: "blocked", Metadata: map[string]interface{}{
					"purpose": purpose, "failure_count": maxInt64(targetFailures, sourceFailures),
				},
			})
		}
		return true, nil
	}
	return false, nil
}

func (s *EmailVerificationService) hashValue(value string) string {
	mac := hmac.New(sha256.New, s.ipSecret)
	_, _ = mac.Write([]byte(strings.TrimSpace(value)))
	return hex.EncodeToString(mac.Sum(nil))
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func (s *EmailVerificationService) hashIP(ip string) string {
	if s.security != nil {
		return s.security.Hash(ip)
	}
	mac := hmac.New(sha256.New, s.ipSecret)
	_, _ = mac.Write([]byte(strings.TrimSpace(ip)))
	return hex.EncodeToString(mac.Sum(nil))
}

func generateEmailVerificationCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}
