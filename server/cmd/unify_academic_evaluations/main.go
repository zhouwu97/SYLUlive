package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"shenliyuan/internal/services"
)

func main() {
	apply := flag.Bool("apply", false, "按已预览计划关联历史评价")
	backup := flag.Bool("backup-confirmed", false, "确认数据库及当前二进制已有可恢复备份")
	plan := flag.String("expected-plan", "", "只读预览报告中的 fingerprint")
	flag.Parse()
	if *apply && (!*backup || *plan == "") {
		fmt.Fprintln(os.Stderr, "执行必须同时提供 --backup-confirmed 和 --expected-plan")
		os.Exit(1)
	}
	dsn := strings.TrimSpace(os.Getenv("DSN"))
	if dsn == "" {
		fmt.Fprintln(os.Stderr, "必须显式设置 DSN 环境变量；不使用默认数据库")
		os.Exit(1)
	}
	var dialect gorm.Dialector
	if strings.HasPrefix(dsn, "postgres://") || strings.HasPrefix(dsn, "postgresql://") || strings.Contains(dsn, "host=") {
		dialect = postgres.Open(dsn)
	} else {
		if _, err := os.Stat(dsn); err != nil {
			fmt.Fprintln(os.Stderr, "SQLite 目标文件必须已存在")
			os.Exit(1)
		}
		mode := "ro"
		if *apply {
			mode = "rw"
		}
		dialect = sqlite.Open("file:" + dsn + "?mode=" + mode)
	}
	db, err := gorm.Open(dialect, &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		fmt.Fprintln(os.Stderr, "连接目标数据库失败；未输出 DSN 或凭据")
		os.Exit(1)
	}
	connection, err := db.DB()
	if err != nil {
		fmt.Fprintln(os.Stderr, "获取数据库连接失败")
		os.Exit(1)
	}
	defer connection.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	report, err := services.UnifyAcademicEvaluations(ctx, db, services.AcademicUnificationOptions{
		Apply: *apply, BackupConfirmed: *backup, ExpectedPlan: *plan,
	})
	encoded, encodeErr := json.MarshalIndent(report, "", "  ")
	if encodeErr != nil {
		fmt.Fprintln(os.Stderr, "生成脱敏报告失败")
		os.Exit(1)
	}
	fmt.Println(string(encoded))
	if err != nil {
		fmt.Fprintln(os.Stderr, "迁移未执行或事务已回滚；请核对备份、预览指纹及冲突报告")
		os.Exit(1)
	}
}
