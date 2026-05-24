package main

import (
	"log"
	"strings"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"

	"shenliyuan/internal/config"
	"shenliyuan/internal/models"
)

func main() {
	cfg := config.Load()
	var db *gorm.DB
	var err error

	if strings.Contains(cfg.DSN, "host=") || strings.Contains(cfg.DSN, "port=") {
		db, err = gorm.Open(postgres.Open(cfg.DSN), &gorm.Config{})
		log.Println("使用 PostgreSQL 数据库")
	} else {
		// adjust path since this script is inside cmd/backfill_exp but config uses relative DSN
		// actually, it runs from server root if we run it like `go run cmd/backfill_exp/main.go`
		db, err = gorm.Open(sqlite.Open(cfg.DSN), &gorm.Config{})
		log.Println("使用 SQLite 数据库")
	}

	if err != nil {
		log.Fatal("数据库连接失败:", err)
	}

	// 自动迁移 ExpLog，以防服务器尚未启动过
	db.AutoMigrate(&models.ExpLog{}, &models.User{})

	// 1. 扫描所有的帖子，寻找历史补分机会
	var posts []models.Post
	if err := db.Find(&posts).Error; err == nil {
		for _, p := range posts {
			date := p.CreatedAt.Truncate(24 * time.Hour)
			txErr := db.Transaction(func(tx *gorm.DB) error {
				expLog := models.ExpLog{
					UserID:    p.AuthorID,
					Action:    "post_daily",
					Date:      date,
					ExpEarned: 5,
				}
				if err := tx.Create(&expLog).Error; err != nil {
					return err
				}
				if err := tx.Model(&models.User{}).Where("id = ?", p.AuthorID).UpdateColumn("exp", gorm.Expr("exp + ?", 5)).Error; err != nil {
					return err
				}
				return nil
			})
			if txErr == nil {
				log.Printf("用户 %d 补充了 %s 的发帖经验 5 点", p.AuthorID, date.Format("2006-01-02"))
			}
		}
	}

	// 2. 扫描所有的回复
	var replies []models.Reply
	if err := db.Find(&replies).Error; err == nil {
		for _, r := range replies {
			date := r.CreatedAt.Truncate(24 * time.Hour)
			txErr := db.Transaction(func(tx *gorm.DB) error {
				expLog := models.ExpLog{
					UserID:    r.AuthorID,
					Action:    "reply_daily",
					Date:      date,
					ExpEarned: 3,
				}
				if err := tx.Create(&expLog).Error; err != nil {
					return err
				}
				if err := tx.Model(&models.User{}).Where("id = ?", r.AuthorID).UpdateColumn("exp", gorm.Expr("exp + ?", 3)).Error; err != nil {
					return err
				}
				return nil
			})
			if txErr == nil {
				log.Printf("用户 %d 补充了 %s 的回复经验 3 点", r.AuthorID, date.Format("2006-01-02"))
			}
		}
	}

	log.Println("经验补充完成！")
}
