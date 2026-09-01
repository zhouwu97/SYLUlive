package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"regexp"
	"strings"

	"github.com/glebarez/sqlite"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"shenliyuan/internal/config"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

const defaultIdentityBackfillBatchSize = 500

var scriptSHAFormat = regexp.MustCompile(`^[0-9a-f]{7,64}$`)

type commandOptions struct {
	Apply           bool
	BackupConfirmed bool
	BatchSize       int
	ScriptSHA       string
}

func main() {
	options, err := parseCommandOptions(os.Args[1:], os.Stderr)
	if err != nil {
		log.Fatal(err)
	}
	db, err := openDatabase(config.Load().DSN)
	if err != nil {
		log.Fatal("连接数据库失败: ", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		log.Fatal("读取数据库连接失败: ", err)
	}
	defer func() {
		if err := sqlDB.Close(); err != nil {
			log.Printf("关闭数据库连接失败: %v", err)
		}
	}()
	if err := runBackfill(context.Background(), db, options, os.Stdout); err != nil {
		log.Fatal(err)
	}
}

func parseCommandOptions(args []string, errorOutput io.Writer) (commandOptions, error) {
	var options commandOptions
	flags := flag.NewFlagSet("backfill_account_identities", flag.ContinueOnError)
	flags.SetOutput(errorOutput)
	flags.BoolVar(&options.Apply, "apply", false, "执行 Identity 回填；省略时只做 dry-run")
	flags.BoolVar(&options.BackupConfirmed, "backup-confirmed", false, "确认数据库备份已完成并验证可读")
	flags.IntVar(&options.BatchSize, "batch-size", defaultIdentityBackfillBatchSize, "每批扫描用户数")
	flags.StringVar(&options.ScriptSHA, "script-sha", "", "本次部署使用的脚本或提交 SHA")
	if err := flags.Parse(args); err != nil {
		return commandOptions{}, err
	}
	if flags.NArg() != 0 {
		return commandOptions{}, fmt.Errorf("不支持位置参数: %s", strings.Join(flags.Args(), " "))
	}
	options.ScriptSHA = strings.ToLower(strings.TrimSpace(options.ScriptSHA))
	if !scriptSHAFormat.MatchString(options.ScriptSHA) {
		return commandOptions{}, errors.New("必须通过 --script-sha 提供 7 至 64 位十六进制 SHA")
	}
	if options.BatchSize <= 0 || options.BatchSize > 10000 {
		return commandOptions{}, errors.New("--batch-size 必须在 1 到 10000 之间")
	}
	if options.Apply && !options.BackupConfirmed {
		return commandOptions{}, errors.New("写入操作必须同时提供 --backup-confirmed")
	}
	return options, nil
}

func openDatabase(dsn string) (*gorm.DB, error) {
	var dialector gorm.Dialector = sqlite.Open(dsn)
	normalized := strings.ToLower(strings.TrimSpace(dsn))
	if strings.HasPrefix(normalized, "postgres://") || strings.HasPrefix(normalized, "postgresql://") ||
		strings.Contains(normalized, "host=") || strings.Contains(normalized, "port=") || strings.Contains(normalized, "user=") {
		dialector = postgres.Open(dsn)
	}
	// 生产回填不允许 ORM 错误日志插值输出邮箱等标识，命令只打印聚合审计结果。
	return gorm.Open(dialector, &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
}

func runBackfill(ctx context.Context, db *gorm.DB, options commandOptions, output io.Writer) error {
	if err := validateSchema(db); err != nil {
		return err
	}
	mode := "dry-run"
	if options.Apply {
		mode = "apply"
	}
	batchCount := 0
	report, err := services.BackfillVerifiedEmailIdentities(ctx, db, services.IdentityBackfillOptions{
		BatchSize: options.BatchSize,
		DryRun:    !options.Apply,
		OnBatch: func(batch services.IdentityBackfillBatchReport) error {
			batchCount = batch.Batch
			return writeBackfillAudit(output, "batch", batch.Batch, mode, options.ScriptSHA, batch.Scanned,
				batch.Written, batch.Skipped, batch.Conflicts, batch.Invalid, options.Apply)
		},
	})
	if err != nil {
		return fmt.Errorf("Identity 回填失败: %w", err)
	}
	if err := writeBackfillAudit(output, "total", batchCount, mode, options.ScriptSHA, report.Scanned,
		report.Written, report.Skipped, report.Conflicts, report.Invalid, options.Apply); err != nil {
		return fmt.Errorf("写入回填总计失败: %w", err)
	}
	reconcile, err := services.ReconcileEmailIdentityMirror(ctx, db)
	if err != nil {
		return fmt.Errorf("Identity 对账失败: %w", err)
	}
	if _, err := fmt.Fprintf(output,
		"scope=reconcile mode=%s script_sha=%s verified_email_users=%d active_email_identities=%d missing_identity=%d mirror_mismatch=%d identity_user_mismatch=%d\n",
		mode, options.ScriptSHA, reconcile.VerifiedEmailUsers, reconcile.ActiveEmailIdentities,
		reconcile.MissingIdentity, reconcile.MirrorMismatch, reconcile.IdentityUserMismatch); err != nil {
		return fmt.Errorf("写入对账摘要失败: %w", err)
	}
	if options.Apply && (report.Conflicts != 0 || report.Invalid != 0 || reconcile.MissingIdentity != 0 ||
		reconcile.MirrorMismatch != 0 || reconcile.IdentityUserMismatch != 0) {
		return fmt.Errorf(
			"Identity 回填未达到读切换条件: conflicts=%d invalid=%d missing_identity=%d mirror_mismatch=%d identity_user_mismatch=%d",
			report.Conflicts, report.Invalid, reconcile.MissingIdentity, reconcile.MirrorMismatch, reconcile.IdentityUserMismatch,
		)
	}
	return nil
}

func validateSchema(db *gorm.DB) error {
	if db == nil {
		return errors.New("数据库未配置")
	}
	if !db.Migrator().HasTable(&models.User{}) || !db.Migrator().HasColumn(&models.User{}, "email_verified_at") {
		return errors.New("目标数据库缺少 users.email_verified_at，请先完成 Identity Expand")
	}
	if !db.Migrator().HasTable(&models.UserLoginIdentity{}) {
		return errors.New("目标数据库缺少 user_login_identities，请先完成 Identity Expand")
	}
	return nil
}

func writeBackfillAudit(
	output io.Writer,
	scope string,
	batch int,
	mode string,
	scriptSHA string,
	scanned int64,
	eligibleOrWritten int64,
	skipped int64,
	conflicts int64,
	invalid int64,
	apply bool,
) error {
	wouldWrite := eligibleOrWritten
	written := int64(0)
	if apply {
		wouldWrite = 0
		written = eligibleOrWritten
	}
	_, err := fmt.Fprintf(output,
		"scope=%s batch=%d mode=%s script_sha=%s scanned=%d would_write=%d written=%d skipped=%d conflicts=%d invalid=%d\n",
		scope, batch, mode, scriptSHA, scanned, wouldWrite, written, skipped, conflicts, invalid)
	return err
}
