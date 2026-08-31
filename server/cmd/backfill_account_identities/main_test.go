package main

import (
	"bytes"
	"context"
	"io"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"shenliyuan/internal/models"
)

const testScriptSHA = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func TestParseCommandOptionsDefaultsToDryRun(t *testing.T) {
	options, err := parseCommandOptions([]string{"--script-sha", strings.ToUpper(testScriptSHA)}, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if options.Apply {
		t.Fatal("未显式提供 --apply 时必须保持 dry-run")
	}
	if options.BatchSize != defaultIdentityBackfillBatchSize {
		t.Fatalf("默认批大小=%d，期望=%d", options.BatchSize, defaultIdentityBackfillBatchSize)
	}
	if options.ScriptSHA != testScriptSHA {
		t.Fatalf("脚本 SHA 未规范化: %q", options.ScriptSHA)
	}
}

func TestParseCommandOptionsRequiresBackupForApply(t *testing.T) {
	if _, err := parseCommandOptions([]string{"--apply", "--script-sha", testScriptSHA}, io.Discard); err == nil {
		t.Fatal("显式写入但未确认备份时必须拒绝")
	}
	options, err := parseCommandOptions([]string{
		"--apply", "--backup-confirmed", "--batch-size", "25", "--script-sha", testScriptSHA,
	}, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if !options.Apply || !options.BackupConfirmed || options.BatchSize != 25 {
		t.Fatalf("写入参数解析错误: %+v", options)
	}
}

func TestRunBackfillDryRunDoesNotWriteAndEmitsRedactedBatchAudit(t *testing.T) {
	db := openBackfillTestDB(t)
	now := time.Date(2026, time.August, 31, 12, 0, 0, 0, time.UTC)
	users := []models.User{
		{Email: "first@example.com", EmailVerifiedAt: &now, PasswordHash: "hash"},
		{Email: "second@example.com", EmailVerifiedAt: &now, PasswordHash: "hash"},
	}
	if err := db.Create(&users).Error; err != nil {
		t.Fatal(err)
	}

	var output bytes.Buffer
	if err := runBackfill(context.Background(), db, commandOptions{
		BatchSize: 1, ScriptSHA: testScriptSHA,
	}, &output); err != nil {
		t.Fatal(err)
	}
	var identityCount int64
	if err := db.Model(&models.UserLoginIdentity{}).Count(&identityCount).Error; err != nil {
		t.Fatal(err)
	}
	if identityCount != 0 {
		t.Fatalf("dry-run 写入了 %d 条 Identity", identityCount)
	}
	audit := output.String()
	if strings.Count(audit, "scope=batch") != 2 || !strings.Contains(audit, "scope=total batch=2 mode=dry-run") {
		t.Fatalf("批次审计不完整:\n%s", audit)
	}
	if !strings.Contains(audit, "would_write=2 written=0") || !strings.Contains(audit, "missing_identity=2") {
		t.Fatalf("dry-run 汇总或对账错误:\n%s", audit)
	}
	if strings.Contains(audit, "@") || strings.Contains(audit, "first") || strings.Contains(audit, "second") {
		t.Fatalf("审计输出泄露了邮箱标识:\n%s", audit)
	}
}

func TestRunBackfillApplyWritesAndReconciles(t *testing.T) {
	db := openBackfillTestDB(t)
	now := time.Date(2026, time.August, 31, 12, 0, 0, 0, time.UTC)
	user := models.User{Email: "apply@example.com", EmailVerifiedAt: &now, PasswordHash: "hash"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}

	var output bytes.Buffer
	if err := runBackfill(context.Background(), db, commandOptions{
		Apply: true, BackupConfirmed: true, BatchSize: 10, ScriptSHA: testScriptSHA,
	}, &output); err != nil {
		t.Fatal(err)
	}
	var identity models.UserLoginIdentity
	if err := db.Where("user_id = ? AND type = ?", user.ID, models.LoginIdentityTypeEmail).First(&identity).Error; err != nil {
		t.Fatal(err)
	}
	if identity.IdentifierNormalized != user.Email || identity.VerifiedAt == nil {
		t.Fatalf("写入 Identity 错误: %+v", identity)
	}
	audit := output.String()
	if !strings.Contains(audit, "mode=apply") || !strings.Contains(audit, "would_write=0 written=1") ||
		!strings.Contains(audit, "missing_identity=0") || !strings.Contains(audit, "mirror_mismatch=0") {
		t.Fatalf("apply 汇总或对账错误:\n%s", audit)
	}
}

func TestRunBackfillApplyFailsClosedAfterPrintingIncompleteSummary(t *testing.T) {
	db := openBackfillTestDB(t)
	now := time.Date(2026, time.August, 31, 12, 0, 0, 0, time.UTC)
	invalid := models.User{Email: "invalid-email", EmailVerifiedAt: &now, PasswordHash: "hash"}
	if err := db.Create(&invalid).Error; err != nil {
		t.Fatal(err)
	}

	var output bytes.Buffer
	err := runBackfill(context.Background(), db, commandOptions{
		Apply: true, BackupConfirmed: true, BatchSize: 10, ScriptSHA: testScriptSHA,
	}, &output)
	if err == nil || !strings.Contains(err.Error(), "invalid=1") || !strings.Contains(err.Error(), "missing_identity=1") {
		t.Fatalf("未完成回填没有返回失败: %v", err)
	}
	audit := output.String()
	if !strings.Contains(audit, "scope=total") || !strings.Contains(audit, "invalid=1") ||
		!strings.Contains(audit, "scope=reconcile") || !strings.Contains(audit, "missing_identity=1") {
		t.Fatalf("失败前未打印完整脱敏摘要:\n%s", audit)
	}
	if strings.Contains(audit, "invalid-email") {
		t.Fatalf("失败摘要泄露邮箱标识:\n%s", audit)
	}
}

func openBackfillTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "identity-backfill.db")), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
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
