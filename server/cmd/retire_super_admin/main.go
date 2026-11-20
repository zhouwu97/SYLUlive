package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"os"
	"time"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"shenliyuan/internal/config"
	"shenliyuan/internal/handlers"
)

func main() {
	keeper := flag.Uint("keep-id", 0, "保留的当前生产种子超级管理员 ID")
	retiring := flag.Uint("retire-id", 0, "经授权要永久匿名化注销的原超级管理员 ID")
	flag.Parse()
	if *keeper == 0 || *retiring == 0 || *keeper == *retiring || flag.NArg() != 0 {
		flag.Usage()
		os.Exit(2)
	}

	cfg := config.Load()
	db, err := gorm.Open(postgres.Open(cfg.DSN), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		log.Fatal("连接注销数据库失败")
	}
	pool, err := db.DB()
	if err != nil {
		log.Fatal("获取注销数据库连接失败")
	}
	defer pool.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	pending, err := handlers.NewPrivacyHandler(db).RetireSuperAdmin(ctx, *keeper, *retiring, cfg.SuperAdminID)
	if err != nil {
		log.Fatalf("超级管理员交接注销失败: %v", err)
	}
	if err := json.NewEncoder(os.Stdout).Encode(map[string]any{
		"kept_super_admin_id": *keeper, "cancelled_user_id": *retiring, "cleanup_pending": pending,
	}); err != nil {
		log.Fatal(err)
	}
}
