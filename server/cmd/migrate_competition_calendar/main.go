package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"strings"

	"gorm.io/driver/postgres"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/config"
	"shenliyuan/internal/models"
)

func main() {
	apply := flag.Bool("apply", false, "执行软删除和条件唯一索引迁移")
	backupConfirmed := flag.Bool("backup-confirmed", false, "确认数据库备份已经完成")
	flag.Parse()

	cfg := config.Load()
	var dialector gorm.Dialector = sqlite.Open(cfg.DSN)
	if strings.Contains(cfg.DSN, "host=") || strings.Contains(cfg.DSN, "port=") {
		dialector = postgres.Open(cfg.DSN)
	}
	db, err := gorm.Open(dialector, &gorm.Config{})
	if err != nil {
		log.Fatal(err)
	}
	if !db.Migrator().HasTable(&models.UserCompetitionCalendarItem{}) {
		if !*apply || !*backupConfirmed {
			log.Fatal("目标表不存在；新环境请使用 --apply --backup-confirmed 初始化迁移")
		}
		if err := db.AutoMigrate(&models.UserCompetitionCalendarItem{}); err != nil {
			log.Fatal(err)
		}
	}
	report, err := models.InspectCompetitionCalendarDuplicates(db)
	if err != nil {
		log.Fatal(err)
	}
	if !*apply {
		printReport(report)
		return
	}
	if !*backupConfirmed {
		log.Fatal("拒绝执行：必须同时提供 --backup-confirmed")
	}
	report, err = models.ApplyCompetitionCalendarDedupMigration(db)
	if err != nil {
		log.Fatal(err)
	}
	printReport(report)
}

func printReport(report models.CompetitionDedupReport) {
	data, _ := json.MarshalIndent(report, "", "  ")
	fmt.Println(string(data))
}
