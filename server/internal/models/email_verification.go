package models

import "time"

const (
	EmailVerificationPurposeRegister      = "register"
	EmailVerificationPurposeBind          = "bind"
	EmailVerificationPurposeChange        = "change"
	EmailVerificationPurposeResetPassword = "reset_password"
)

// EmailVerificationChallenge 保存一次性邮箱验证码的哈希和消费状态。
// 明文验证码绝不能落库或写入日志。
type EmailVerificationChallenge struct {
	ID            uint       `gorm:"primaryKey"`
	UserID        *uint      `gorm:"index"`
	Email         string     `gorm:"size:320;not null;index"`
	Purpose       string     `gorm:"size:32;not null;index"`
	CodeHash      string     `gorm:"size:255;not null"`
	Attempts      int        `gorm:"default:0;not null"`
	ExpiresAt     time.Time  `gorm:"not null;index"`
	ConsumedAt    *time.Time `gorm:"index"`
	RequestIPHash string     `gorm:"size:64;not null;index"`
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

// EmailVerificationRequest 记录公开验证码请求的限流证据。
// 即使邮箱未绑定账号也会写入，避免响应路径泄露账号是否存在。
type EmailVerificationRequest struct {
	ID            uint      `gorm:"primaryKey"`
	Email         string    `gorm:"size:320;not null;index"`
	Purpose       string    `gorm:"size:32;not null;index"`
	RequestIPHash string    `gorm:"size:64;not null;index"`
	CreatedAt     time.Time `gorm:"index"`
}

// AccountSecurityAuditLog 记录身份和教务连接的安全关键操作。
type AccountSecurityAuditLog struct {
	ID        uint      `gorm:"primaryKey"`
	UserID    uint      `gorm:"not null;index"`
	Action    string    `gorm:"size:64;not null;index"`
	Metadata  string    `gorm:"type:text;not null;default:''"`
	CreatedAt time.Time `gorm:"index"`
}
