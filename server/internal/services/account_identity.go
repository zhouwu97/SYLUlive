package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

var (
	ErrIdentityConflict       = errors.New("login identity belongs to another account")
	ErrIdentityDisabled       = errors.New("login identity is disabled")
	ErrIdentityTypeInvalid    = errors.New("login identity type is invalid")
	ErrIdempotencyKeyRequired = errors.New("idempotency key is required")
	ErrIdempotencyKeyReused   = errors.New("idempotency key was used for another request")
	ErrRegistrationCommit     = errors.New("registration commit failed")
)

// NormalizeLoginIdentity 对不同身份类型使用明确的规范化规则。
func NormalizeLoginIdentity(identityType, value string) (string, error) {
	switch identityType {
	case models.LoginIdentityTypeEmail:
		return NormalizeEmail(value)
	case models.LoginIdentityTypeLegacyStudent:
		// 迁移期只接受 ASCII 数字学号；不保留用户提交的首尾展示空白。
		normalized := strings.Trim(value, " \t\r\n\f\v")
		if normalized == "" || len(normalized) > 20 {
			return "", ErrIdentityTypeInvalid
		}
		for _, r := range normalized {
			if r < '0' || r > '9' {
				return "", ErrIdentityTypeInvalid
			}
		}
		return normalized, nil
	default:
		return "", ErrIdentityTypeInvalid
	}
}

// FindActiveEmailIdentity 只查找有效邮箱 Identity，不回退查询 users.student_id。
func FindActiveEmailIdentity(tx *gorm.DB, email string) (models.UserLoginIdentity, error) {
	var identity models.UserLoginIdentity
	normalized, err := NormalizeEmail(email)
	if err != nil {
		return identity, err
	}
	err = tx.Where("type = ? AND identifier_normalized = ? AND disabled_at IS NULL AND verified_at IS NOT NULL",
		models.LoginIdentityTypeEmail, normalized).First(&identity).Error
	return identity, err
}

// CreateEmailIdentity 在事务中建立邮箱 Identity。查询包含 disabled 行，默认禁止把历史
// 标识自动转移到另一 user.id；恢复流程必须由单独的审计操作完成。
func CreateEmailIdentity(tx *gorm.DB, userID uint, email string, verifiedAt time.Time) (models.UserLoginIdentity, error) {
	if tx == nil || userID == 0 {
		return models.UserLoginIdentity{}, errors.New("identity transaction and user are required")
	}
	normalized, err := NormalizeEmail(email)
	if err != nil {
		return models.UserLoginIdentity{}, err
	}
	if verifiedAt.IsZero() {
		verifiedAt = time.Now().UTC()
	}
	// PostgreSQL 下用事务级 advisory lock 串行化同一规范化标识，避免两个事务
	// 同时通过预查后才在唯一索引处失败。锁参数是摘要，不记录原始邮箱。
	if tx.Dialector.Name() == "postgres" {
		if err := tx.Exec("SELECT pg_advisory_xact_lock(hashtext(?))", "identity:"+normalized).Error; err != nil {
			return models.UserLoginIdentity{}, err
		}
	}
	var existing models.UserLoginIdentity
	err = tx.Where("type = ? AND identifier_normalized = ?", models.LoginIdentityTypeEmail, normalized).
		Clauses(clause.Locking{Strength: "UPDATE"}).
		Order("CASE WHEN disabled_at IS NULL THEN 0 ELSE 1 END").Order("id ASC").
		First(&existing).Error
	if err == nil {
		if existing.UserID != userID {
			if existing.DisabledAt != nil {
				return models.UserLoginIdentity{}, ErrIdentityDisabled
			}
			return models.UserLoginIdentity{}, ErrIdentityConflict
		}
		if existing.DisabledAt != nil {
			return models.UserLoginIdentity{}, ErrIdentityDisabled
		}
		if existing.VerifiedAt == nil {
			if err := tx.Model(&existing).Updates(map[string]interface{}{
				"verified_at": verifiedAt, "updated_at": verifiedAt,
			}).Error; err != nil {
				return models.UserLoginIdentity{}, err
			}
			existing.VerifiedAt = &verifiedAt
			existing.UpdatedAt = verifiedAt
		}
		return existing, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return models.UserLoginIdentity{}, err
	}
	identity := models.UserLoginIdentity{
		UserID: userID, Type: models.LoginIdentityTypeEmail,
		IdentifierNormalized: normalized, VerifiedAt: &verifiedAt,
		CreatedAt: verifiedAt, UpdatedAt: verifiedAt,
	}
	if err := tx.Create(&identity).Error; err != nil {
		return models.UserLoginIdentity{}, err
	}
	return identity, nil
}

// DisableLoginIdentity 阻断迁移期旧登录，但不删除历史行；PR12 再执行硬删除。
func DisableLoginIdentity(tx *gorm.DB, userID uint, identityType, value string, now time.Time) error {
	if tx == nil || userID == 0 {
		return errors.New("identity transaction and user are required")
	}
	normalized, err := NormalizeLoginIdentity(identityType, value)
	if err != nil {
		return err
	}
	if now.IsZero() {
		now = time.Now().UTC()
	}
	result := tx.Model(&models.UserLoginIdentity{}).
		Where("user_id = ? AND type = ? AND identifier_normalized = ? AND disabled_at IS NULL", userID, identityType, normalized).
		Updates(map[string]interface{}{"disabled_at": now, "updated_at": now})
	return result.Error
}

// RegistrationCommitInput 描述最终注册提交。PasswordHash 必须是调用方生成的 bcrypt
// 哈希，服务层不接收或记录明文 APP Password。
type RegistrationCommitInput struct {
	SessionID      string
	IdempotencyKey string
	Email          string
	PasswordHash   string
	Now            time.Time
	// CreateUser 可写入昵称、角色和法律同意；必须使用传入的事务。
	CreateUser func(tx *gorm.DB, normalizedEmail string, passwordHash string) (*models.User, error)
}

type RegistrationCommitResult struct {
	UserID   uint
	Replayed bool
}

// CommitRegistrationSession 在单一数据库事务中锁定 Session、建立 User/Email Identity
// 并消费 Session。重复提交只返回第一次的 user.id，不会创建第二个账号。
func CommitRegistrationSession(ctx context.Context, db *gorm.DB, input RegistrationCommitInput) (RegistrationCommitResult, error) {
	var result RegistrationCommitResult
	if db == nil {
		return result, errors.New("registration database is required")
	}
	if strings.TrimSpace(input.SessionID) == "" || len(input.SessionID) > 64 {
		return result, models.ErrRegistrationSessionNotFound
	}
	key := strings.TrimSpace(input.IdempotencyKey)
	if key == "" || len(key) > 200 || strings.ContainsAny(key, "\r\n") {
		return result, ErrIdempotencyKeyRequired
	}
	if strings.TrimSpace(input.PasswordHash) == "" {
		return result, errors.New("password hash is required")
	}
	normalizedEmail, err := NormalizeEmail(input.Email)
	if err != nil {
		return result, err
	}
	now := input.Now
	if now.IsZero() {
		now = time.Now().UTC()
	}
	now = now.UTC()
	keyHash := sha256HexString(key)
	tx := db.WithContext(ctx)
	var committedTerminalErr error
	err = tx.Transaction(func(tx *gorm.DB) error {
		var session models.RegistrationSession
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&session, "id = ?", input.SessionID).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return models.ErrRegistrationSessionNotFound
			}
			return err
		}
		if session.State == models.RegistrationSessionConsumed {
			if session.ConsumedAt == nil || session.ConsumedUserID == nil {
				return ErrRegistrationCommit
			}
			if session.IdempotencyKeyHash == keyHash && session.ConsumedUserID != nil {
				result = RegistrationCommitResult{UserID: *session.ConsumedUserID, Replayed: true}
				return nil
			}
			return ErrRegistrationCommit
		}
		if session.ConsumedAt != nil || session.ConsumedUserID != nil {
			return ErrRegistrationCommit
		}
		if session.IsTerminal() {
			if session.State == models.RegistrationSessionExpired {
				return models.ErrRegistrationSessionExpired
			}
			return models.ErrRegistrationSessionLocked
		}
		if session.State != models.RegistrationSessionReady {
			return models.ErrRegistrationSessionNotReady
		}
		if !models.IsRegistrationPolicyValid(session.PolicyVersion) {
			return models.ErrRegistrationPolicy
		}
		if !now.Before(session.ExpiresAt) {
			if err := session.MarkExpired(now); err != nil {
				return err
			}
			if err := tx.Model(&session).Updates(map[string]interface{}{
				"state": session.State, "lock_version": session.LockVersion, "updated_at": now,
			}).Error; err != nil {
				return err
			}
			// 返回 nil 让 EXPIRED 终态提交；业务错误在事务提交后返回给调用方。
			committedTerminalErr = models.ErrRegistrationSessionExpired
			return nil
		}
		if session.IdempotencyKeyHash != "" && session.IdempotencyKeyHash != keyHash {
			return ErrIdempotencyKeyReused
		}
		if session.IdempotencyKeyHash == "" {
			if err := tx.Model(&session).Updates(map[string]interface{}{"idempotency_key_hash": keyHash, "updated_at": now}).Error; err != nil {
				return err
			}
		}
		createUser := input.CreateUser
		if createUser == nil {
			createUser = func(tx *gorm.DB, email string, passwordHash string) (*models.User, error) {
				user := &models.User{
					Email: email, EmailVerifiedAt: &now, PasswordHash: passwordHash,
					Role: models.RoleUser, AccountStatus: "active", EduSessionState: "unbound",
				}
				if err := tx.Create(user).Error; err != nil {
					return nil, err
				}
				return user, nil
			}
		}
		user, err := createUser(tx, normalizedEmail, input.PasswordHash)
		if err != nil {
			return err
		}
		if user == nil || user.ID == 0 {
			return errors.New("registration callback did not create user")
		}
		// 双写 compatibility mirror；回调可先写入其他字段，但邮箱必须在同一事务
		// 中与 Identity 保持一致。
		if err := tx.Model(&models.User{}).Where("id = ?", user.ID).Updates(map[string]interface{}{
			"email": normalizedEmail, "email_verified_at": now,
		}).Error; err != nil {
			return err
		}
		if _, err := CreateEmailIdentity(tx, user.ID, normalizedEmail, now); err != nil {
			return err
		}
		if err := session.Transition(models.RegistrationSessionConsumed, now); err != nil {
			return err
		}
		consumedUserID := user.ID
		session.ConsumedUserID = &consumedUserID
		if err := tx.Model(&session).Updates(map[string]interface{}{
			"state": session.State, "consumed_at": session.ConsumedAt,
			"consumed_user_id": consumedUserID, "lock_version": session.LockVersion,
			"updated_at": session.UpdatedAt,
		}).Error; err != nil {
			return err
		}
		result = RegistrationCommitResult{UserID: user.ID}
		return nil
	})
	if err != nil {
		return RegistrationCommitResult{}, err
	}
	if committedTerminalErr != nil {
		return RegistrationCommitResult{}, committedTerminalErr
	}
	return result, nil
}

// CreateRegistrationSession 持久化新 Session；调用方只传入不含个人标识的 challenge ID。
func CreateRegistrationSession(ctx context.Context, db *gorm.DB, policyVersion, challengeID string, now time.Time) (models.RegistrationSession, error) {
	if db == nil {
		return models.RegistrationSession{}, errors.New("registration database is required")
	}
	session, err := models.NewRegistrationSession(policyVersion, challengeID, now)
	if err != nil {
		return session, err
	}
	if err := db.WithContext(ctx).Create(&session).Error; err != nil {
		return models.RegistrationSession{}, err
	}
	return session, nil
}

// TransitionRegistrationSession 在行锁事务内推进 Session 状态。
func TransitionRegistrationSession(ctx context.Context, db *gorm.DB, id string, next models.RegistrationSessionState, now time.Time) error {
	if db == nil {
		return errors.New("registration database is required")
	}
	// CONSUMED 必须与 user.id 在最终提交事务中原子写入，不能走通用状态推进。
	if next == models.RegistrationSessionConsumed {
		return models.ErrRegistrationTransition
	}
	return db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var session models.RegistrationSession
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&session, "id = ?", id).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return models.ErrRegistrationSessionNotFound
			}
			return err
		}
		if err := session.Transition(next, now); err != nil {
			return err
		}
		return tx.Model(&session).Updates(map[string]interface{}{
			"state": session.State, "consumed_at": session.ConsumedAt,
			"lock_version": session.LockVersion, "updated_at": session.UpdatedAt,
		}).Error
	})
}

// CleanupRegistrationSessions 将过期活动 Session 标记为 EXPIRED，并删除超过保留期的终态行。
// 返回物理删除数量；不会输出任何标识或 Session 内容。
func CleanupRegistrationSessions(ctx context.Context, db *gorm.DB, now time.Time, batchSize int) (int64, error) {
	if db == nil {
		return 0, errors.New("registration database is required")
	}
	if now.IsZero() {
		now = time.Now().UTC()
	}
	if batchSize <= 0 {
		batchSize = 500
	}
	tx := db.WithContext(ctx)
	if err := tx.Model(&models.RegistrationSession{}).
		Where("state IN ? AND expires_at <= ?", []models.RegistrationSessionState{
			models.RegistrationSessionPending, models.RegistrationSessionEmailVerified,
			models.RegistrationSessionAdmissionReady, models.RegistrationSessionReady,
		}, now).
		Updates(map[string]interface{}{
			"state": models.RegistrationSessionExpired, "updated_at": now,
			"lock_version": gorm.Expr("lock_version + 1"),
		}).Error; err != nil {
		return 0, err
	}
	cutoff := now.Add(-models.RegistrationTerminalRetention)
	var ids []string
	if err := tx.Model(&models.RegistrationSession{}).
		Where("state IN ? AND updated_at <= ?", []models.RegistrationSessionState{
			models.RegistrationSessionConsumed, models.RegistrationSessionExpired, models.RegistrationSessionLocked,
		}, cutoff).Order("updated_at ASC").Limit(batchSize).Pluck("id", &ids).Error; err != nil {
		return 0, err
	}
	if len(ids) == 0 {
		return 0, nil
	}
	res := tx.Where("id IN ?", ids).Delete(&models.RegistrationSession{})
	return res.RowsAffected, res.Error
}

func sha256HexString(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

// NewOpaqueChallengeID 用于测试和调用方生成不携带个人信息的挑战标识。
func NewOpaqueChallengeID() string { return uuid.NewString() }

// Compile-time guard against accidental removal of the public error contract.
var _ = fmt.Sprintf
