package models

import "time"

// SecurityEvent 是面向安全中心的聚合事件，不保存密码、令牌、Cookie、请求体或明文 IP。
// BucketKey 由事件类型、来源/目标摘要、路由和五分钟时间桶组成，避免攻击者通过日志写入放大数据库压力。
type SecurityEvent struct {
	ID                        uint       `gorm:"primaryKey" json:"id"`
	BucketKey                 string     `gorm:"size:512;not null;uniqueIndex" json:"-"`
	EventType                 string     `gorm:"size:64;not null;index" json:"event_type"`
	Severity                  string     `gorm:"size:16;not null;index" json:"severity"`
	Status                    string     `gorm:"size:20;not null;index" json:"status"`
	Route                     string     `gorm:"size:160;not null;index" json:"route"`
	Method                    string     `gorm:"size:12;not null" json:"method"`
	SourceIPHash              string     `gorm:"size:64;index" json:"-"`
	SourceAttributionValid    bool       `gorm:"not null;default:true;index" json:"source_attribution_valid"`
	SourceUAHash              string     `gorm:"size:64" json:"-"`
	InstallationHash          string     `gorm:"size:64;index" json:"-"`
	ActorUserID               *uint      `gorm:"index" json:"actor_user_id,omitempty"`
	TargetType                string     `gorm:"size:32;index" json:"target_type"`
	TargetHash                string     `gorm:"size:64;index" json:"-"`
	TargetMasked              string     `gorm:"size:320" json:"target_masked"`
	RequestIDSample           string     `gorm:"size:128" json:"request_id_sample"`
	AttemptCount              int        `gorm:"not null;default:1" json:"attempt_count"`
	BlockedCount              int        `gorm:"not null;default:0" json:"blocked_count"`
	MailSentCount             int        `gorm:"not null;default:0" json:"mail_sent_count"`
	PasswordResetSuccessCount int        `gorm:"not null;default:0" json:"password_reset_success_count"`
	Action                    string     `gorm:"size:24;not null" json:"action"`
	MetadataJSON              string     `gorm:"type:text;not null;default:''" json:"metadata_json,omitempty"`
	FirstSeenAt               time.Time  `gorm:"index" json:"first_seen_at"`
	LastSeenAt                time.Time  `gorm:"index" json:"last_seen_at"`
	ResolvedAt                *time.Time `json:"resolved_at,omitempty"`
	ResolvedBy                *uint      `json:"resolved_by,omitempty"`
	ResolutionNote            string     `gorm:"size:500;not null;default:''" json:"resolution_note,omitempty"`
	CreatedAt                 time.Time  `json:"created_at"`
	UpdatedAt                 time.Time  `json:"updated_at"`
}

const (
	SecurityEventStatusActive        = "active"
	SecurityEventStatusResolved      = "resolved"
	SecurityEventStatusFalsePositive = "false_positive"

	SecuritySeverityInfo     = "info"
	SecuritySeverityLow      = "low"
	SecuritySeverityMedium   = "medium"
	SecuritySeverityHigh     = "high"
	SecuritySeverityCritical = "critical"
)

// SecurityBlock 是管理员创建的临时来源阻断。ScopeValue 只允许保存 HMAC 摘要。
type SecurityBlock struct {
	ID          uint       `gorm:"primaryKey" json:"id"`
	GroupID     string     `gorm:"size:36;index" json:"group_id"`
	ScopeType   string     `gorm:"size:24;not null;index" json:"scope_type"`
	ScopeValue  string     `gorm:"size:64;not null;index" json:"scope_value"`
	RoutePrefix string     `gorm:"size:160;not null;default:''" json:"route_prefix"`
	Reason      string     `gorm:"size:200;not null;default:''" json:"reason"`
	ExpiresAt   time.Time  `gorm:"not null;index" json:"expires_at"`
	CreatedBy   uint       `gorm:"not null;index" json:"created_by"`
	CreatedAt   time.Time  `json:"created_at"`
	RevokedAt   *time.Time `gorm:"index" json:"revoked_at,omitempty"`
	RevokedBy   *uint      `json:"revoked_by,omitempty"`
}

// VerificationAttemptBucket 统计目标/来源在十分钟窗口内的验证码失败次数。
// challenge 轮换不会改变 bucket，因此重新发码不能刷新暴力尝试额度。
type VerificationAttemptBucket struct {
	ID           uint      `gorm:"primaryKey"`
	BucketKey    string    `gorm:"size:256;not null;uniqueIndex"`
	ScopeType    string    `gorm:"size:16;not null;index"`
	ScopeValue   string    `gorm:"size:128;not null;index"`
	Purpose      string    `gorm:"size:32;not null;index"`
	BucketStart  time.Time `gorm:"not null;index"`
	FailureCount int       `gorm:"not null;default:0"`
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

// VerificationAttempt 保存单次验证码失败，仅保留不可逆摘要，按创建时间支持真实滚动窗口统计。
// 与固定时间桶不同，窗口边界不会漏算或重复计算攻击尝试。
type VerificationAttempt struct {
	ID         uint      `gorm:"primaryKey"`
	TargetHash string    `gorm:"size:64;not null;index"`
	SourceHash string    `gorm:"size:64;not null;index"`
	Purpose    string    `gorm:"size:32;not null;index"`
	CreatedAt  time.Time `gorm:"index"`
}
