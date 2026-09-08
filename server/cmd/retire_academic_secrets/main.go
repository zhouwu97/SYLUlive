package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"os"
	"shenliyuan/internal/services"
)

func main() {
	apply := flag.Bool("apply", false, "执行旧凭据撤销并创建跨服务清理任务；默认只盘点")
	accepted := flag.Bool("clients-accepted", false, "确认本科和研究生客户端生命周期均已验收")
	minimum := flag.Int64("minimum-client-version", 0, "已发布的最低支持客户端版本号")
	flag.Parse()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		fmt.Fprintln(os.Stderr, "请通过 DATABASE_URL 配置目标数据库")
		os.Exit(2)
	}
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		fmt.Fprintln(os.Stderr, "数据库连接失败，请检查配置")
		os.Exit(1)
	}
	ctx := context.Background()
	if *apply {
		if err = services.PrepareAcademicRetirement(ctx, db, os.Getenv("SCHOOL_LEGACY_SECRETS_FROZEN") == "true", *accepted, *minimum); err != nil {
			fmt.Fprintln(os.Stderr, "清理未完成：请核对冻结、验收与最低版本条件，并检查数据库事务")
			os.Exit(1)
		}
	}
	report, err := services.InventoryAcademicRetirement(ctx, db)
	if err != nil {
		fmt.Fprintln(os.Stderr, "盘点失败，请检查数据库迁移状态")
		os.Exit(1)
	}
	_ = json.NewEncoder(os.Stdout).Encode(report)
}
