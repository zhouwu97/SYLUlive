package main

import (
	"context"
	"encoding/json"
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
	apply := flag.Bool("apply", false, "执行非破坏性旧赛事重复归并")
	backupConfirmed := flag.Bool("backup-confirmed", false, "确认数据库与当前二进制备份已完成")
	expectedTotal := flag.Int("expected-total", 930, "预期旧赛事总数")
	expectedGroups := flag.Int("expected-groups", 310, "预期身份组数")
	expectedCopies := flag.Int("expected-copies", 3, "每个身份的预期上传副本数")
	canonicalMinID := flag.Uint("canonical-min-id", 621, "最新成功上传的最小事件 ID")
	canonicalMaxID := flag.Uint("canonical-max-id", 930, "最新成功上传的最大事件 ID")
	actorUserID := flag.Uint("actor-user-id", 0, "执行归并的管理员用户 ID，运维执行可保持 0")
	flag.Parse()
	if *apply && !*backupConfirmed {
		log.Fatal("拒绝执行：写入必须同时提供 --backup-confirmed")
	}

	cfg := config.Load()
	var dialector gorm.Dialector = sqlite.Open(cfg.DSN)
	if strings.Contains(cfg.DSN, "host=") || strings.Contains(cfg.DSN, "port=") ||
		strings.Contains(cfg.DSN, "user=") {
		dialector = postgres.Open(cfg.DSN)
	}
	db, err := gorm.Open(dialector, &gorm.Config{})
	if err != nil {
		log.Fatal("连接数据库失败:", err)
	}
	if !db.Migrator().HasTable(&models.CompetitionEvent{}) {
		log.Fatal("目标数据库不存在 competition_events 表")
	}

	report, err := services.NewLegacyCompetitionReconciler(db).Reconcile(
		context.Background(),
		services.LegacyCompetitionReconciliationOptions{
			Apply: *apply, BackupConfirmed: *backupConfirmed,
			ExpectedTotal: *expectedTotal, ExpectedGroups: *expectedGroups,
			ExpectedCopies: *expectedCopies,
			CanonicalMinID: *canonicalMinID, CanonicalMaxID: *canonicalMaxID,
			ActorUserID: *actorUserID,
		},
	)
	encoded, encodeErr := json.MarshalIndent(report, "", "  ")
	if encodeErr != nil {
		log.Fatal("编码归并报告失败:", encodeErr)
	}
	fmt.Println(string(encoded))
	if err != nil {
		log.Fatal("旧赛事重复归并失败:", err)
	}
}
