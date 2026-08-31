package main

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/config"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func TestValidateAccountIdentityReadinessSkipsLegacyMode(t *testing.T) {
	if err := validateAccountIdentityReadiness(context.Background(), nil, config.AccountIdentityReadModeLegacy); err != nil {
		t.Fatalf("legacy 模式不应执行 Identity 对账: %v", err)
	}
}

func TestValidateAccountIdentityReadinessRejectsIdentityModeWithMissingRows(t *testing.T) {
	db := openIdentityReadinessTestDB(t)
	now := time.Date(2026, time.August, 31, 12, 0, 0, 0, time.UTC)
	user := models.User{Email: "missing@example.com", EmailVerifiedAt: &now, PasswordHash: "hash"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}

	err := validateAccountIdentityReadiness(context.Background(), db, config.AccountIdentityReadModeIdentity)
	if err == nil || !strings.Contains(err.Error(), "missing_identity=1") || !strings.Contains(err.Error(), "mirror_mismatch=1") {
		t.Fatalf("缺失 Identity 未阻断启动: %v", err)
	}
}

func TestValidateAccountIdentityReadinessRejectsMirrorAndUserMismatch(t *testing.T) {
	db := openIdentityReadinessTestDB(t)
	now := time.Date(2026, time.August, 31, 12, 0, 0, 0, time.UTC)
	user := models.User{Email: "primary@example.com", EmailVerifiedAt: &now, PasswordHash: "hash"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	if _, err := services.CreateEmailIdentity(db, user.ID, user.Email, now); err != nil {
		t.Fatal(err)
	}
	if _, err := services.CreateEmailIdentity(db, user.ID, "secondary@example.com", now); err != nil {
		t.Fatal(err)
	}

	err := validateAccountIdentityReadiness(context.Background(), db, config.AccountIdentityReadModeIdentity)
	if err == nil || !strings.Contains(err.Error(), "identity_user_mismatch=1") {
		t.Fatalf("一个用户拥有多个有效 Identity 时未阻断启动: %v", err)
	}
}

func TestValidateAccountIdentityReadinessAllowsReconciledIdentityMode(t *testing.T) {
	db := openIdentityReadinessTestDB(t)
	now := time.Date(2026, time.August, 31, 12, 0, 0, 0, time.UTC)
	user := models.User{Email: "ready@example.com", EmailVerifiedAt: &now, PasswordHash: "hash"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	if _, err := services.CreateEmailIdentity(db, user.ID, user.Email, now); err != nil {
		t.Fatal(err)
	}

	if err := validateAccountIdentityReadiness(context.Background(), db, config.AccountIdentityReadModeIdentity); err != nil {
		t.Fatalf("已对账 Identity 模式被错误阻断: %v", err)
	}
}

func openIdentityReadinessTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "identity-readiness.db")), &gorm.Config{})
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
	if err := db.AutoMigrate(&models.User{}); err != nil {
		t.Fatal(err)
	}
	if err := models.EnsureAccountIdentitySchema(db); err != nil {
		t.Fatal(err)
	}
	return db
}
