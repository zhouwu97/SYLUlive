package services

import (
	"context"
	"errors"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

var accountIdentityServiceDBSequence atomic.Uint64

func openAccountIdentityServiceDB(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := fmt.Sprintf("file:account-identity-service-%d?mode=memory&cache=shared", accountIdentityServiceDBSequence.Add(1))
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := sqlDB.Close(); err != nil {
			t.Errorf("关闭测试数据库失败: %v", err)
		}
	})
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}); err != nil {
		t.Fatal(err)
	}
	if err := models.EnsureAccountIdentitySchema(db); err != nil {
		t.Fatal(err)
	}
	return db
}

func readyRegistrationSession(t *testing.T, db *gorm.DB, now time.Time) models.RegistrationSession {
	t.Helper()
	session, err := models.NewRegistrationSession(models.RegistrationPolicyEmailV2, "challenge-id", now)
	if err != nil {
		t.Fatal(err)
	}
	for _, state := range []models.RegistrationSessionState{
		models.RegistrationSessionEmailVerified,
		models.RegistrationSessionReady,
	} {
		if err := session.Transition(state, now); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Create(&session).Error; err != nil {
		t.Fatal(err)
	}
	return session
}

func TestNormalizeEmailUsesIDNAAndRejectsControlCharacters(t *testing.T) {
	got, err := NormalizeEmail("  User@例子.中国 \t")
	if err != nil {
		t.Fatalf("IDNA 邮箱应有效: %v", err)
	}
	if got != "user@xn--fsqu00a.xn--fiqs8s" {
		t.Fatalf("规范化结果=%q", got)
	}
	for _, input := range []string{"user+tag@example.com", "user..dots@example.com", "a\x00b@example.com", "a@@example.com", "@example.com", "a@example"} {
		if _, err := NormalizeEmail(input); err != nil && input == "user+tag@example.com" {
			t.Fatalf("+tag 不应被特殊折叠: %v", err)
		}
	}
	if _, err := NormalizeEmail("a\x00b@example.com"); !errors.Is(err, ErrEmailInvalid) {
		t.Fatalf("控制字符错误=%v", err)
	}
}

func TestCreateEmailIdentityRejectsDisabledIdentityTransfer(t *testing.T) {
	db := openAccountIdentityServiceDB(t)
	now := time.Now().UTC()
	first := models.User{PasswordHash: "hash", AccountStatus: "active"}
	second := models.User{PasswordHash: "hash", AccountStatus: "active"}
	if err := db.Create(&first).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&second).Error; err != nil {
		t.Fatal(err)
	}
	if _, err := CreateEmailIdentity(db, first.ID, "first@example.com", now); err != nil {
		t.Fatal(err)
	}
	if err := DisableLoginIdentity(db, first.ID, models.LoginIdentityTypeEmail, "FIRST@example.com", now); err != nil {
		t.Fatal(err)
	}
	if _, err := CreateEmailIdentity(db, second.ID, " first@example.com ", now); !errors.Is(err, ErrIdentityDisabled) {
		t.Fatalf("禁用身份转移错误=%v", err)
	}
}

func TestCreateEmailIdentityPrefersActiveRowOverDisabledHistory(t *testing.T) {
	db := openAccountIdentityServiceDB(t)
	now := time.Now().UTC()
	oldUser := models.User{PasswordHash: "hash", AccountStatus: "active"}
	activeUser := models.User{PasswordHash: "hash", AccountStatus: "active"}
	if err := db.Create(&oldUser).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&activeUser).Error; err != nil {
		t.Fatal(err)
	}
	disabledAt := now.Add(-time.Minute)
	rows := []models.UserLoginIdentity{
		{UserID: oldUser.ID, Type: models.LoginIdentityTypeEmail, IdentifierNormalized: "history@example.com", VerifiedAt: &now, DisabledAt: &disabledAt},
		{UserID: activeUser.ID, Type: models.LoginIdentityTypeEmail, IdentifierNormalized: "history@example.com", VerifiedAt: &now},
	}
	if err := db.Create(&rows).Error; err != nil {
		t.Fatal(err)
	}
	identity, err := CreateEmailIdentity(db, activeUser.ID, "HISTORY@example.com", now)
	if err != nil {
		t.Fatalf("有效 Identity 不应被更早的禁用历史遮蔽: %v", err)
	}
	if identity.UserID != activeUser.ID || identity.DisabledAt != nil {
		t.Fatalf("返回了错误 Identity: %+v", identity)
	}
}

func TestFindActiveEmailIdentityRequiresVerification(t *testing.T) {
	db := openAccountIdentityServiceDB(t)
	user := models.User{PasswordHash: "hash", AccountStatus: "active"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.UserLoginIdentity{
		UserID: user.ID, Type: models.LoginIdentityTypeEmail,
		IdentifierNormalized: "unverified@example.com",
	}).Error; err != nil {
		t.Fatal(err)
	}
	if _, err := FindActiveEmailIdentity(db, "unverified@example.com"); !errors.Is(err, gorm.ErrRecordNotFound) {
		t.Fatalf("未验证 Identity 不应可登录，错误=%v", err)
	}
}

func TestCommitRegistrationSessionRejectsUnknownPolicy(t *testing.T) {
	db := openAccountIdentityServiceDB(t)
	now := time.Now().UTC()
	session := readyRegistrationSession(t, db, now)
	if err := db.Model(&session).Update("policy_version", "removed_policy").Error; err != nil {
		t.Fatal(err)
	}
	input := RegistrationCommitInput{
		SessionID: session.ID, IdempotencyKey: "unknown-policy-key",
		Email: "policy@example.com", PasswordHash: "hash", Now: now,
	}
	if _, err := CommitRegistrationSession(context.Background(), db, input); !errors.Is(err, models.ErrRegistrationPolicy) {
		t.Fatalf("未知策略应拒绝提交，错误=%v", err)
	}
}

func TestCommitRegistrationSessionIsIdempotentAndMirrorsEmail(t *testing.T) {
	db := openAccountIdentityServiceDB(t)
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	session := readyRegistrationSession(t, db, now)
	hash, err := bcrypt.GenerateFromPassword([]byte("app-password"), bcrypt.MinCost)
	if err != nil {
		t.Fatal(err)
	}
	input := RegistrationCommitInput{
		SessionID: session.ID, IdempotencyKey: "registration-key-1",
		Email: " NewUser@Example.COM ", PasswordHash: string(hash), Now: now,
	}
	var createCalls atomic.Int32
	input.CreateUser = func(tx *gorm.DB, email string, passwordHash string) (*models.User, error) {
		createCalls.Add(1)
		user := &models.User{PasswordHash: passwordHash, Role: models.RoleUser, AccountStatus: "active"}
		if err := tx.Create(user).Error; err != nil {
			return nil, err
		}
		return user, nil
	}
	result, err := CommitRegistrationSession(context.Background(), db, input)
	if err != nil {
		t.Fatalf("首次提交失败: %v", err)
	}
	if result.UserID == 0 || result.Replayed || createCalls.Load() != 1 {
		t.Fatalf("首次提交结果错误: %+v calls=%d", result, createCalls.Load())
	}
	result, err = CommitRegistrationSession(context.Background(), db, input)
	if err != nil {
		t.Fatalf("幂等重放失败: %v", err)
	}
	if !result.Replayed || result.UserID == 0 || result.UserID != inputUserID(t, db, session.ID) || createCalls.Load() != 1 {
		t.Fatalf("重放结果错误: %+v calls=%d", result, createCalls.Load())
	}
	var user models.User
	if err := db.First(&user, result.UserID).Error; err != nil {
		t.Fatal(err)
	}
	if user.Email != "newuser@example.com" || user.EmailVerifiedAt == nil {
		t.Fatalf("用户邮箱镜像错误: %+v", user)
	}
	var count int64
	if err := db.Model(&models.UserLoginIdentity{}).Where("user_id = ?", result.UserID).Count(&count).Error; err != nil || count != 1 {
		t.Fatalf("邮箱 Identity 数量=%d err=%v", count, err)
	}
}

func inputUserID(t *testing.T, db *gorm.DB, sessionID string) uint {
	t.Helper()
	var session models.RegistrationSession
	if err := db.First(&session, "id = ?", sessionID).Error; err != nil {
		t.Fatal(err)
	}
	if session.ConsumedUserID == nil {
		t.Fatal("Session 未记录消费用户")
	}
	return *session.ConsumedUserID
}

func TestCommitRegistrationSessionRejectsDifferentIdempotencyKey(t *testing.T) {
	db := openAccountIdentityServiceDB(t)
	now := time.Now().UTC()
	session := readyRegistrationSession(t, db, now)
	input := RegistrationCommitInput{SessionID: session.ID, IdempotencyKey: "key-a", Email: "a@example.com", PasswordHash: "hash", Now: now}
	if _, err := CommitRegistrationSession(context.Background(), db, input); err != nil {
		t.Fatal(err)
	}
	input.IdempotencyKey = "key-b"
	if _, err := CommitRegistrationSession(context.Background(), db, input); !errors.Is(err, ErrRegistrationCommit) {
		t.Fatalf("不同幂等键错误=%v", err)
	}
}

func TestCommitRegistrationSessionPersistsExpiredTerminalState(t *testing.T) {
	db := openAccountIdentityServiceDB(t)
	createdAt := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	session := readyRegistrationSession(t, db, createdAt)
	expiredAt := session.ExpiresAt
	input := RegistrationCommitInput{
		SessionID: session.ID, IdempotencyKey: "expired-session-key",
		Email: "expired@example.com", PasswordHash: "hash", Now: expiredAt,
	}
	if _, err := CommitRegistrationSession(context.Background(), db, input); !errors.Is(err, models.ErrRegistrationSessionExpired) {
		t.Fatalf("过期提交错误=%v", err)
	}
	var stored models.RegistrationSession
	if err := db.First(&stored, "id = ?", session.ID).Error; err != nil {
		t.Fatal(err)
	}
	if stored.State != models.RegistrationSessionExpired || stored.LockVersion != session.LockVersion+1 {
		t.Fatalf("过期终态未提交: %+v", stored)
	}
	var userCount int64
	if err := db.Model(&models.User{}).Where("email = ?", "expired@example.com").Count(&userCount).Error; err != nil || userCount != 0 {
		t.Fatalf("过期提交不应创建用户: count=%d err=%v", userCount, err)
	}
}

func TestTransitionRegistrationSessionRejectsConsumedWithoutUser(t *testing.T) {
	db := openAccountIdentityServiceDB(t)
	now := time.Now().UTC()
	session := readyRegistrationSession(t, db, now)
	if err := TransitionRegistrationSession(context.Background(), db, session.ID, models.RegistrationSessionConsumed, now); !errors.Is(err, models.ErrRegistrationTransition) {
		t.Fatalf("通用状态推进不应允许 CONSUMED，错误=%v", err)
	}
	var stored models.RegistrationSession
	if err := db.First(&stored, "id = ?", session.ID).Error; err != nil {
		t.Fatal(err)
	}
	if stored.State != models.RegistrationSessionReady || stored.ConsumedAt != nil || stored.ConsumedUserID != nil {
		t.Fatalf("拒绝消费后 Session 被修改: %+v", stored)
	}
}

func TestBackfillVerifiedEmailIdentitiesClassifiesOutcomes(t *testing.T) {
	db := openAccountIdentityServiceDB(t)
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	users := []models.User{
		{Email: "same@example.com", EmailVerifiedAt: &now, PasswordHash: "hash", AccountStatus: "active"},
		{Email: "owned@example.com", EmailVerifiedAt: &now, PasswordHash: "hash", AccountStatus: "active"},
		{Email: "invalid-email", EmailVerifiedAt: &now, PasswordHash: "hash", AccountStatus: "active"},
		{Email: "write@example.com", EmailVerifiedAt: &now, PasswordHash: "hash", AccountStatus: "active"},
		{PasswordHash: "hash", AccountStatus: "active"},
	}
	if err := db.Create(&users).Error; err != nil {
		t.Fatal(err)
	}
	if _, err := CreateEmailIdentity(db, users[0].ID, users[0].Email, now); err != nil {
		t.Fatal(err)
	}
	if _, err := CreateEmailIdentity(db, users[4].ID, users[1].Email, now); err != nil {
		t.Fatal(err)
	}
	want := IdentityBackfillReport{Scanned: 4, Written: 1, Skipped: 1, Conflicts: 1, Invalid: 1}
	dryRun, err := BackfillVerifiedEmailIdentities(context.Background(), db, IdentityBackfillOptions{DryRun: true, BatchSize: 2, Now: now})
	if err != nil || dryRun != want {
		t.Fatalf("dry-run 报告=%+v err=%v，期望=%+v", dryRun, err, want)
	}
	actual, err := BackfillVerifiedEmailIdentities(context.Background(), db, IdentityBackfillOptions{BatchSize: 2, Now: now})
	if err != nil || actual != want {
		t.Fatalf("实际回填报告=%+v err=%v，期望=%+v", actual, err, want)
	}
	second, err := BackfillVerifiedEmailIdentities(context.Background(), db, IdentityBackfillOptions{BatchSize: 2, Now: now})
	wantSecond := IdentityBackfillReport{Scanned: 4, Skipped: 2, Conflicts: 1, Invalid: 1}
	if err != nil || second != wantSecond {
		t.Fatalf("幂等回填报告=%+v err=%v，期望=%+v", second, err, wantSecond)
	}
}

func TestCleanupRegistrationSessionsDeletesOnlyOldTerminalRows(t *testing.T) {
	db := openAccountIdentityServiceDB(t)
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	old := now.Add(-models.RegistrationTerminalRetention - time.Minute)
	rows := []models.RegistrationSession{
		{ID: "old-expired", State: models.RegistrationSessionExpired, PolicyVersion: models.RegistrationPolicyEmailV2, ExpiresAt: old, CreatedAt: old, UpdatedAt: old},
		{ID: "new-expired", State: models.RegistrationSessionExpired, PolicyVersion: models.RegistrationPolicyEmailV2, ExpiresAt: now, CreatedAt: now, UpdatedAt: now},
		{ID: "active-expired", State: models.RegistrationSessionReady, PolicyVersion: models.RegistrationPolicyEmailV2, ExpiresAt: now.Add(-time.Minute), CreatedAt: now, UpdatedAt: now},
	}
	if err := db.Create(&rows).Error; err != nil {
		t.Fatal(err)
	}
	deleted, err := CleanupRegistrationSessions(context.Background(), db, now, 10)
	if err != nil || deleted != 1 {
		t.Fatalf("清理结果 deleted=%d err=%v", deleted, err)
	}
	var active models.RegistrationSession
	if err := db.First(&active, "id = ?", "active-expired").Error; err != nil {
		t.Fatal(err)
	}
	if active.State != models.RegistrationSessionExpired {
		t.Fatalf("活动过期 Session 未标记: %s", active.State)
	}
	if active.LockVersion != 1 {
		t.Fatalf("批量过期未递增 lock_version: %d", active.LockVersion)
	}
}
