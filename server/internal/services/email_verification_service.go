package services

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"mime"
	"net/smtp"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/crypto/bcrypt"
	"golang.org/x/net/idna"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

const emailVerificationCodeTTL = 10 * time.Minute

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
	ErrPurposeInvalid    = errors.New("验证码用途无效")
	ErrMailNotConfigured = errors.New("服务器未配置邮件服务")
)

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
	SendVerificationCode(email string, purpose string, code string) error
}

// SMTPVerificationMailer 使用已有 SMTP 配置发送验证码邮件。
type SMTPVerificationMailer struct {
	config SMTPConfig
}

func NewSMTPVerificationMailer(config SMTPConfig) *SMTPVerificationMailer {
	return &SMTPVerificationMailer{config: config}
}

func (m *SMTPVerificationMailer) SendVerificationCode(email string, purpose string, code string) error {
	if strings.TrimSpace(m.config.Host) == "" || strings.TrimSpace(m.config.User) == "" || strings.TrimSpace(m.config.Pass) == "" || strings.TrimSpace(m.config.From) == "" {
		return ErrMailNotConfigured
	}
	port := strings.TrimSpace(m.config.Port)
	if port == "" {
		port = "587"
	}
	auth := smtp.PlainAuth("", m.config.User, m.config.Pass, m.config.Host)
	return smtp.SendMail(
		m.config.Host+":"+port,
		auth,
		m.config.From,
		[]string{email},
		buildVerificationEmail(email, m.config.From, purpose, code),
	)
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
	db       *gorm.DB
	mailer   VerificationMailer
	ipSecret []byte
	now      func() time.Time
}

func NewEmailVerificationService(db *gorm.DB, mailer VerificationMailer, ipSecret string, now func() time.Time) *EmailVerificationService {
	if now == nil {
		now = time.Now
	}
	return &EmailVerificationService{db: db, mailer: mailer, ipSecret: []byte(ipSecret), now: now}
}

func NormalizeEmail(input string) (string, error) {
	// 只去除协议约定的 ASCII 空白；其余控制字符一律拒绝，避免展示值与
	// 唯一性判断使用不同的规范化规则。不会应用 Gmail 点号或 +tag 特例。
	email := strings.Trim(input, " \t\r\n\f\v")
	if email == "" || !utf8.ValidString(email) || len(email) > 320 || strings.IndexFunc(email, func(r rune) bool {
		return r < 0x20 || r == 0x7f
	}) >= 0 {
		return "", ErrEmailInvalid
	}
	if strings.Count(email, "@") != 1 || !emailPattern.MatchString(email) {
		return "", ErrEmailInvalid
	}
	parts := strings.SplitN(email, "@", 2)
	local, domain := parts[0], parts[1]
	if local == "" || domain == "" || len(local) > 64 {
		return "", ErrEmailInvalid
	}
	// IDNA 只作用于域名；本地部分按项目规则整体转小写，不做供应商特例。
	asciiDomain, err := idna.Lookup.ToASCII(domain)
	if err != nil || asciiDomain == "" || len(asciiDomain) > 255 {
		return "", ErrEmailInvalid
	}
	normalized := strings.ToLower(local) + "@" + strings.ToLower(asciiDomain)
	if len(normalized) > 320 || !emailPattern.MatchString(normalized) {
		return "", ErrEmailInvalid
	}
	return normalized, nil
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
	return s.createAndSend(email, purpose, userID, clientIP, true)
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
	now := s.now()
	ipHash := s.hashIP(clientIP)
	return s.db.Transaction(func(tx *gorm.DB) error {
		if tx.Dialector.Name() == "postgres" {
			for _, scope := range []string{"public-email:" + normalized, "public-ip:" + ipHash} {
				if err := tx.Exec("SELECT pg_advisory_xact_lock(hashtext(?))", scope).Error; err != nil {
					return err
				}
			}
		}
		var sentToEmail int64
		if err := tx.Model(&models.EmailVerificationRequest{}).
			Where("email = ? AND created_at >= ?", normalized, now.Add(-time.Hour)).
			Count(&sentToEmail).Error; err != nil {
			return err
		}
		if sentToEmail >= 5 {
			return ErrEmailRateLimited
		}
		var sentFromIP int64
		if err := tx.Model(&models.EmailVerificationRequest{}).
			Where("request_ip_hash = ? AND created_at >= ?", ipHash, now.Add(-time.Hour)).
			Count(&sentFromIP).Error; err != nil {
			return err
		}
		if sentFromIP >= 10 {
			return ErrIPRateLimited
		}
		var latest models.EmailVerificationRequest
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("email = ? AND purpose = ?", normalized, purpose).
			Order("created_at DESC").First(&latest).Error
		if err == nil && now.Sub(latest.CreatedAt) < time.Minute {
			return ErrSendTooFrequently
		}
		if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		return tx.Create(&models.EmailVerificationRequest{
			Email: normalized, Purpose: purpose, RequestIPHash: ipHash, CreatedAt: now,
		}).Error
	})
}

// SendReservedPublicRequest 为已存在账号发送已完成公开限流预留的验证码。
func (s *EmailVerificationService) SendReservedPublicRequest(email string, purpose string, userID *uint, clientIP string) error {
	return s.createAndSend(email, purpose, userID, clientIP, false)
}

func (s *EmailVerificationService) createAndSend(email string, purpose string, userID *uint, clientIP string, enforceChallengeRateLimit bool) error {
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
	if err := s.db.Transaction(func(tx *gorm.DB) error {
		if enforceChallengeRateLimit && tx.Dialector.Name() == "postgres" {
			for _, scope := range []string{"email:" + normalized, "ip:" + ipHash} {
				if err := tx.Exec("SELECT pg_advisory_xact_lock(hashtext(?))", scope).Error; err != nil {
					return err
				}
			}
		}
		if enforceChallengeRateLimit {
			var sentToEmail int64
			if err := tx.Model(&models.EmailVerificationChallenge{}).
				Where("email = ? AND created_at >= ?", normalized, now.Add(-time.Hour)).
				Count(&sentToEmail).Error; err != nil {
				return err
			}
			if sentToEmail >= 5 {
				return ErrEmailRateLimited
			}
			var sentFromIP int64
			if err := tx.Model(&models.EmailVerificationChallenge{}).
				Where("request_ip_hash = ? AND created_at >= ?", ipHash, now.Add(-time.Hour)).
				Count(&sentFromIP).Error; err != nil {
				return err
			}
			if sentFromIP >= 10 {
				return ErrIPRateLimited
			}
			var latest models.EmailVerificationChallenge
			err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
				Where("email = ? AND purpose = ?", normalized, purpose).
				Order("created_at DESC").First(&latest).Error
			if err == nil && now.Sub(latest.CreatedAt) < time.Minute {
				return ErrSendTooFrequently
			}
			if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
				return err
			}
		}
		return tx.Create(&challenge).Error
	}); err != nil {
		return err
	}
	if err := s.mailer.SendVerificationCode(normalized, purpose, code); err != nil {
		// 邮件发送失败的验证码不能继续有效，用户可立即重新请求。
		_ = s.db.Delete(&models.EmailVerificationChallenge{}, challenge.ID).Error
		return err
	}
	return nil
}

func (s *EmailVerificationService) Validate(email string, purpose string, code string, consume bool) error {
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
			// 业务校验失败不能作为事务错误返回，否则尝试次数更新会被回滚。
			validationErr = ErrCodeInvalid
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
			validationErr = ErrCodeInvalid
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

func (s *EmailVerificationService) hashIP(ip string) string {
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
