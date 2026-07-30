package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"strings"

	"github.com/glebarez/sqlite"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"

	"shenliyuan/internal/config"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func main() {
	apply := flag.Bool("apply", false, "执行哈希回填")
	backupConfirmed := flag.Bool("backup-confirmed", false, "确认数据库备份已完成并验证可读")
	flag.Parse()
	if *apply && !*backupConfirmed {
		log.Fatal("写入操作必须同时提供 --backup-confirmed")
	}

	cfg := config.Load()
	var dialector gorm.Dialector = sqlite.Open(cfg.DSN)
	if strings.Contains(cfg.DSN, "host=") || strings.Contains(cfg.DSN, "port=") || strings.Contains(cfg.DSN, "user=") {
		dialector = postgres.Open(cfg.DSN)
	}
	db, err := gorm.Open(dialector, &gorm.Config{})
	if err != nil {
		log.Fatal("连接数据库失败:", err)
	}
	if !db.Migrator().HasTable(&models.AcademicSnapshot{}) {
		log.Fatal("目标数据库不存在 academic_snapshots 表")
	}
	report, err := services.BackfillAcademicSnapshotHashes(context.Background(), db, *apply)
	if err != nil {
		log.Fatal("回填失败:", err)
	}
	mode := "dry-run"
	if *apply {
		mode = "apply"
	}
	fmt.Printf("mode=%s total=%d mismatched_or_updated=%d skipped=%d\n", mode, report.Total, report.Updated, report.Skipped)
}
