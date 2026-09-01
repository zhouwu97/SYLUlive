package models

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

// 登录身份类型。StudentID 只作为迁移期独立入口使用，不能混入普通邮箱登录。
const (
	LoginIdentityTypeEmail         = "email"
	LoginIdentityTypeLegacyStudent = "legacy_student_id"
)

// UserLoginIdentity 是账号登录标识的规范化索引。
// identifier_normalized 只保存规范化后的值，不保存用户提交的展示原文。
type UserLoginIdentity struct {
	ID                   uint       `gorm:"primaryKey" json:"-"`
	UserID               uint       `gorm:"not null;index:ix_user_login_identity_user_type,priority:1" json:"user_id"`
	User                 *User      `gorm:"foreignKey:UserID;constraint:OnDelete:CASCADE" json:"-"`
	Type                 string     `gorm:"size:32;not null;index:ix_user_login_identity_user_type,priority:2" json:"type"`
	IdentifierNormalized string     `gorm:"size:320;not null" json:"-"`
	VerifiedAt           *time.Time `json:"-"`
	DisabledAt           *time.Time `gorm:"index:ix_user_login_identity_user_type,priority:3" json:"-"`
	CreatedAt            time.Time  `gorm:"not null" json:"-"`
	UpdatedAt            time.Time  `gorm:"not null" json:"-"`
}

func (UserLoginIdentity) TableName() string { return "user_login_identities" }

func (identity UserLoginIdentity) IsActive() bool {
	return identity.DisabledAt == nil
}

// RegistrationSessionState 表示一次注册提交的服务端状态。
type RegistrationSessionState string

const (
	RegistrationSessionPending        RegistrationSessionState = "pending"
	RegistrationSessionEmailVerified  RegistrationSessionState = "email_verified"
	RegistrationSessionAdmissionReady RegistrationSessionState = "admission_ready"
	RegistrationSessionReady          RegistrationSessionState = "ready"
	RegistrationSessionConsumed       RegistrationSessionState = "consumed"
	RegistrationSessionExpired        RegistrationSessionState = "expired"
	RegistrationSessionLocked         RegistrationSessionState = "locked"
)

// 迁移期和最终期策略版本。策略写入 Session 后不可在运行时静默提升。
const (
	RegistrationPolicyAdmissionV1 = "admission_v1"
	RegistrationPolicyEmailV2     = "email_v2"
)

const (
	RegistrationSessionMaxAge      = 30 * time.Minute
	RegistrationTerminalRetention  = 24 * time.Hour
	RegistrationSessionMaxAttempts = 5
)

var (
	ErrRegistrationSessionNotFound = errors.New("registration session not found")
	ErrRegistrationSessionExpired  = errors.New("registration session expired")
	ErrRegistrationSessionLocked   = errors.New("registration session locked")
	ErrRegistrationSessionConsumed = errors.New("registration session already consumed")
	ErrRegistrationSessionNotReady = errors.New("registration session is not ready")
	ErrRegistrationTransition      = errors.New("invalid registration session transition")
	ErrRegistrationPolicy          = errors.New("unsupported registration policy")
)

// RegistrationSession 只保存注册流程状态，不保存邮箱、学号、学校凭据或学校响应。
type RegistrationSession struct {
	ID               string                   `gorm:"size:64;primaryKey" json:"id"`
	State            RegistrationSessionState `gorm:"size:24;not null;index:ix_registration_sessions_state_expiry,priority:1;index:ix_registration_sessions_terminal_cleanup,priority:1;check:registration_sessions_state_check,state IN ('pending','email_verified','admission_ready','ready','consumed','expired','locked')" json:"state"`
	LockVersion      int64                    `gorm:"not null;default:0" json:"-"`
	EmailChallengeID string                   `gorm:"size:128;not null;default:''" json:"-"`
	AttemptCount     int                      `gorm:"not null;default:0;check:registration_sessions_attempt_check,attempt_count >= 0 AND attempt_count <= 5" json:"-"`
	LastAttemptAt    *time.Time               `gorm:"index" json:"-"`
	PolicyVersion    string                   `gorm:"size:32;not null" json:"-"`
	ExpiresAt        time.Time                `gorm:"not null;index:ix_registration_sessions_state_expiry,priority:2" json:"expires_at"`
	ConsumedAt       *time.Time               `gorm:"check:registration_sessions_consumed_check,(state = 'consumed' AND consumed_at IS NOT NULL AND consumed_user_id IS NOT NULL) OR (state <> 'consumed' AND consumed_at IS NULL AND consumed_user_id IS NULL)" json:"-"`
	// 只保存幂等键摘要，防止原始令牌进入数据库。
	IdempotencyKeyHash string    `gorm:"size:64;not null;default:''" json:"-"`
	ConsumedUserID     *uint     `gorm:"index:ix_registration_sessions_consumed_user" json:"-"`
	ConsumedUser       *User     `gorm:"foreignKey:ConsumedUserID;constraint:OnDelete:RESTRICT" json:"-"`
	CreatedAt          time.Time `gorm:"not null" json:"created_at"`
	UpdatedAt          time.Time `gorm:"not null;index:ix_registration_sessions_terminal_cleanup,priority:2" json:"-"`
}

func (RegistrationSession) TableName() string { return "registration_sessions" }

// NewRegistrationSession 创建默认 30 分钟有效的注册会话。
func NewRegistrationSession(policyVersion, challengeID string, now time.Time) (RegistrationSession, error) {
	if !IsRegistrationPolicyValid(policyVersion) {
		return RegistrationSession{}, ErrRegistrationPolicy
	}
	if strings.ContainsAny(challengeID, "\r\n") || len(challengeID) > 128 {
		return RegistrationSession{}, fmt.Errorf("email challenge id is invalid")
	}
	if now.IsZero() {
		now = time.Now().UTC()
	}
	now = now.UTC()
	return RegistrationSession{
		ID:               uuid.NewString(),
		State:            RegistrationSessionPending,
		PolicyVersion:    policyVersion,
		EmailChallengeID: challengeID,
		ExpiresAt:        now.Add(RegistrationSessionMaxAge),
		CreatedAt:        now,
		UpdatedAt:        now,
	}, nil
}

func IsRegistrationPolicyValid(policy string) bool {
	switch policy {
	case RegistrationPolicyAdmissionV1, RegistrationPolicyEmailV2:
		return true
	default:
		return false
	}
}

func (session RegistrationSession) IsTerminal() bool {
	switch session.State {
	case RegistrationSessionConsumed, RegistrationSessionExpired, RegistrationSessionLocked:
		return true
	default:
		return false
	}
}

func (session RegistrationSession) IsReady(now time.Time) bool {
	if session.State != RegistrationSessionReady || session.ConsumedAt != nil {
		return false
	}
	if now.IsZero() {
		now = time.Now()
	}
	return now.Before(session.ExpiresAt)
}

// CanTransition 只允许前进或进入终态，禁止状态倒退和终态复活。
func (session RegistrationSession) CanTransition(next RegistrationSessionState) bool {
	if session.IsTerminal() {
		return false
	}
	if next == RegistrationSessionExpired || next == RegistrationSessionLocked {
		return true
	}
	switch session.State {
	case RegistrationSessionPending:
		return next == RegistrationSessionEmailVerified
	case RegistrationSessionEmailVerified:
		return next == RegistrationSessionAdmissionReady || next == RegistrationSessionReady
	case RegistrationSessionAdmissionReady:
		return next == RegistrationSessionReady
	case RegistrationSessionReady:
		return next == RegistrationSessionConsumed
	default:
		return false
	}
}

// Transition 在内存中推进状态；持久化由服务层在行锁事务中完成。
func (session *RegistrationSession) Transition(next RegistrationSessionState, now time.Time) error {
	if session == nil {
		return ErrRegistrationTransition
	}
	if !session.CanTransition(next) {
		if session.IsTerminal() {
			return ErrRegistrationTransition
		}
		return ErrRegistrationTransition
	}
	if now.IsZero() {
		now = time.Now()
	}
	now = now.UTC()
	if next != RegistrationSessionExpired && next != RegistrationSessionLocked &&
		!now.Before(session.ExpiresAt) {
		return ErrRegistrationSessionExpired
	}
	if next == RegistrationSessionConsumed {
		session.ConsumedAt = &now
	}
	session.State = next
	session.LockVersion++
	session.UpdatedAt = now
	return nil
}

// MarkExpired/Lock 是终态操作，调用方仍需在数据库事务中保存结果。
func (session *RegistrationSession) MarkExpired(now time.Time) error {
	return session.Transition(RegistrationSessionExpired, now)
}

func (session *RegistrationSession) Lock(now time.Time) error {
	return session.Transition(RegistrationSessionLocked, now)
}

// EnsureAccountIdentitySchema 可重复执行，供启动迁移和本地测试使用。
// 部分唯一性通过显式 SQL 建立，避免把已禁用的历史身份自动转移给其他账号。
func EnsureAccountIdentitySchema(db *gorm.DB) error {
	if db == nil {
		return errors.New("account identity schema migration requires database")
	}
	if err := db.AutoMigrate(&UserLoginIdentity{}, &RegistrationSession{}); err != nil {
		return err
	}
	if err := db.Exec("CREATE UNIQUE INDEX IF NOT EXISTS ux_user_login_identity_active ON user_login_identities (type, identifier_normalized) WHERE disabled_at IS NULL").Error; err != nil {
		return err
	}
	if err := db.Exec("CREATE INDEX IF NOT EXISTS ix_user_login_identity_user_type ON user_login_identities (user_id, type, disabled_at)").Error; err != nil {
		return err
	}
	if err := db.Exec("CREATE INDEX IF NOT EXISTS ix_registration_sessions_state_expiry ON registration_sessions (state, expires_at)").Error; err != nil {
		return err
	}
	if err := db.Exec("CREATE INDEX IF NOT EXISTS ix_registration_sessions_terminal_cleanup ON registration_sessions (state, updated_at)").Error; err != nil {
		return err
	}
	if err := db.Exec("CREATE INDEX IF NOT EXISTS ix_registration_sessions_consumed_user ON registration_sessions (consumed_user_id)").Error; err != nil {
		return err
	}
	return nil
}
