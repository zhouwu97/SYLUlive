package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/glebarez/sqlite"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"shenliyuan/internal/models"
)

func main() {
	apply := flag.Bool("apply", false, "执行签到天数对账修复并记录审计日志")
	inspect := flag.Bool("inspect", false, "只读检查不一致账号（默认行为）")
	userID := flag.Uint("user", 0, "指定仅检查或修复的用户ID（0表示全量）")
	flag.Parse()

	// 默认只读检查
	if !*apply {
		*inspect = true
	}

	dsn := strings.TrimSpace(os.Getenv("DSN"))
	if dsn == "" {
		dsn = "./shenliyuan.db"
	}

	var dialect gorm.Dialector
	if strings.HasPrefix(dsn, "postgres://") || strings.HasPrefix(dsn, "postgresql://") || strings.Contains(dsn, "host=") {
		dialect = postgres.Open(dsn)
	} else {
		dialect = sqlite.Open(dsn)
	}

	db, err := gorm.Open(dialect, &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		fmt.Fprintf(os.Stderr, "连接数据库失败: %v\n", err)
		os.Exit(1)
	}
	sqlDB, err := db.DB()
	if err != nil {
		fmt.Fprintf(os.Stderr, "获取底座连接失败: %v\n", err)
		os.Exit(1)
	}
	defer sqlDB.Close()

	if *userID > 0 {
		if *apply {
			rebuilt, err := models.RebuildUserCheckInStats(db, uint(*userID))
			if err != nil {
				fmt.Fprintf(os.Stderr, "修复用户 %d 失败: %v\n", *userID, err)
				os.Exit(1)
			}
			out, _ := json.MarshalIndent(rebuilt, "", "  ")
			fmt.Printf("用户 %d 签到天数与汇总已重建:\n%s\n", *userID, string(out))
			return
		}
		inconsistency, err := models.InspectUserCheckInStats(db, uint(*userID))
		if err != nil {
			fmt.Fprintf(os.Stderr, "检查用户 %d 失败: %v\n", *userID, err)
			os.Exit(1)
		}
		if inconsistency == nil {
			fmt.Printf("用户 %d 签到数据一致，无需修复\n", *userID)
			return
		}
		out, _ := json.MarshalIndent(inconsistency, "", "  ")
		fmt.Printf("用户 %d 存在签到数据不一致:\n%s\n", *userID, string(out))
		return
	}

	if *apply {
		report, err := models.ReconcileInconsistentCheckInStats(db, 0)
		if err != nil {
			fmt.Fprintf(os.Stderr, "全量修复签到数据失败: %v\n", err)
			os.Exit(1)
		}
		out, _ := json.MarshalIndent(report, "", "  ")
		fmt.Printf("全量签到对账与修复完成:\n%s\n", string(out))
		return
	}

	inconsistencies, err := models.InspectAllUserCheckInStats(db)
	if err != nil {
		fmt.Fprintf(os.Stderr, "全量检查签到数据失败: %v\n", err)
		os.Exit(1)
	}
	if len(inconsistencies) == 0 {
		fmt.Println("所有账号签到连续天数与汇总完全一致，未发现异常")
		return
	}
	out, _ := json.MarshalIndent(inconsistencies, "", "  ")
	fmt.Printf("发现 %d 个账号存在签到连续天数或汇总不一致:\n%s\n", len(inconsistencies), string(out))
}
