package models

import (
	"errors"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestRegistrationSessionStateMachineOnlyMovesForward(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	session, err := NewRegistrationSession(RegistrationPolicyAdmissionV1, "challenge-opaque", now)
	if err != nil {
		t.Fatal(err)
	}
	if session.State != RegistrationSessionPending || session.ExpiresAt != now.Add(RegistrationSessionMaxAge) {
		t.Fatalf("初始 Session 不符合策略: %+v", session)
	}
	for _, next := range []RegistrationSessionState{
		RegistrationSessionEmailVerified,
		RegistrationSessionAdmissionReady,
		RegistrationSessionReady,
	} {
		if err := session.Transition(next, now); err != nil {
			t.Fatalf("推进到 %s 失败: %v", next, err)
		}
	}
	if err := session.Transition(RegistrationSessionEmailVerified, now); !errors.Is(err, ErrRegistrationTransition) {
		t.Fatalf("READY 倒退错误=%v", err)
	}
	if err := session.Transition(RegistrationSessionConsumed, now); err != nil {
		t.Fatalf("消费 Session 失败: %v", err)
	}
	if session.ConsumedAt == nil || !session.IsTerminal() {
		t.Fatalf("消费后终态字段错误: %+v", session)
	}
	if err := session.Transition(RegistrationSessionExpired, now); !errors.Is(err, ErrRegistrationTransition) {
		t.Fatalf("终态复活错误=%v", err)
	}
}

func TestRegistrationSessionExpiresAndLocks(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	session, err := NewRegistrationSession(RegistrationPolicyEmailV2, "", now)
	if err != nil {
		t.Fatal(err)
	}
	if err := session.Transition(RegistrationSessionEmailVerified, now); err != nil {
		t.Fatal(err)
	}
	if err := session.Lock(now); err != nil {
		t.Fatal(err)
	}
	if session.State != RegistrationSessionLocked || session.LockVersion != 2 {
		t.Fatalf("锁定状态错误: %+v", session)
	}
}

func TestRegistrationSessionExpiresAtExactBoundary(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	session, err := NewRegistrationSession(RegistrationPolicyEmailV2, "", now)
	if err != nil {
		t.Fatal(err)
	}
	boundary := session.ExpiresAt
	if err := session.Transition(RegistrationSessionEmailVerified, boundary); !errors.Is(err, ErrRegistrationSessionExpired) {
		t.Fatalf("恰好到期时应拒绝推进，错误=%v", err)
	}
}

func TestEnsureAccountIdentitySchemaIsRepeatable(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&User{}); err != nil {
		t.Fatal(err)
	}
	if err := EnsureAccountIdentitySchema(db); err != nil {
		t.Fatalf("首次迁移失败: %v", err)
	}
	if err := EnsureAccountIdentitySchema(db); err != nil {
		t.Fatalf("重复迁移失败: %v", err)
	}
	user := User{PasswordHash: "hash", AccountStatus: "active"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	first := UserLoginIdentity{UserID: user.ID, Type: LoginIdentityTypeEmail, IdentifierNormalized: "one@example.com"}
	if err := db.Create(&first).Error; err != nil {
		t.Fatal(err)
	}
	second := UserLoginIdentity{UserID: user.ID + 1, Type: LoginIdentityTypeEmail, IdentifierNormalized: "one@example.com"}
	if err := db.Create(&second).Error; err == nil {
		t.Fatal("有效 Identity 唯一约束未生效")
	}
	if err := db.Create(&RegistrationSession{ID: "session-1", State: RegistrationSessionPending, PolicyVersion: RegistrationPolicyEmailV2, ExpiresAt: time.Now().Add(time.Hour)}).Error; err != nil {
		t.Fatal(err)
	}
	for _, indexName := range []string{
		"ix_user_login_identity_user_type",
		"ix_registration_sessions_state_expiry",
		"ix_registration_sessions_terminal_cleanup",
		"ix_registration_sessions_consumed_user",
	} {
		var count int64
		if err := db.Raw("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?", indexName).Scan(&count).Error; err != nil {
			t.Fatalf("检查索引 %s 失败: %v", indexName, err)
		}
		if count != 1 {
			t.Fatalf("索引 %s 数量=%d，期望=1", indexName, count)
		}
	}
	invalidRows := []RegistrationSession{
		{ID: "invalid-state", State: "invalid", PolicyVersion: RegistrationPolicyEmailV2, ExpiresAt: time.Now().Add(time.Hour)},
		{ID: "invalid-attempts", State: RegistrationSessionPending, AttemptCount: RegistrationSessionMaxAttempts + 1, PolicyVersion: RegistrationPolicyEmailV2, ExpiresAt: time.Now().Add(time.Hour)},
		{ID: "invalid-consumed", State: RegistrationSessionConsumed, PolicyVersion: RegistrationPolicyEmailV2, ExpiresAt: time.Now().Add(time.Hour)},
	}
	for _, row := range invalidRows {
		if err := db.Create(&row).Error; err == nil {
			t.Fatalf("非法 Session %s 未被数据库约束拒绝", row.ID)
		}
	}
}
