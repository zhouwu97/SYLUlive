package main

import (
	"log"
	"strings"

	"shenliyuan/internal/config"
	"gorm.io/driver/postgres"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func main() {
	cfg := config.Load()
	var db *gorm.DB
	var err error

	if strings.Contains(cfg.DSN, "host=") || strings.Contains(cfg.DSN, "port=") {
		db, err = gorm.Open(postgres.Open(cfg.DSN), &gorm.Config{})
		log.Println("使用 PostgreSQL 数据库")
	} else {
		db, err = gorm.Open(sqlite.Open(cfg.DSN), &gorm.Config{})
		log.Println("使用 SQLite 数据库")
	}

	if err != nil {
		log.Fatal("数据库连接失败:", err)
	}

	log.Println("开始清理历史明文密码和 Cookie...")
	// 无论字段是否存在，尝试清空数据。如果列不存在会报错，所以忽略错误。
	result := db.Exec("UPDATE users SET edu_password = '', edu_cookie = '' WHERE edu_password != '' OR edu_cookie != ''")
	if result.Error != nil {
		if strings.Contains(result.Error.Error(), "no such column") || strings.Contains(result.Error.Error(), "does not exist") {
			log.Println("历史列不存在，无需清理")
		} else {
			log.Fatalf("清理执行失败: %v\n", result.Error)
		}
	} else {
		log.Printf("成功清理了 %d 条历史数据\n", result.RowsAffected)
	}

	log.Println("清理完成")
}
