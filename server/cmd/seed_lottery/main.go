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
	} else {
		db, err = gorm.Open(sqlite.Open(cfg.DSN), &gorm.Config{})
	}
	if err != nil {
		log.Fatal("连接数据库失败:", err)
	}

	// 自动迁移
	err = db.AutoMigrate(&models.User{}, &models.LotteryEvent{}, &models.LotteryParticipant{})
	if err != nil {
		log.Fatal("迁移失败:", err)
	}

	// 解析2026年6月1日19:00:00时间
	loc, _ := time.LoadLocation("Asia/Shanghai")
	targetTime := time.Date(2026, 6, 1, 19, 0, 0, 0, loc)

	// 创建或更新 B站大会员 抽奖活动
	event := models.LotteryEvent{
		Title:       "2026年度回馈大抽奖",
		Description: "感谢大家一直以来对本应用的支持！为了回馈活跃用户，特此送出福利！",
		PrizeName:   "B站大会员一个月",
		DrawTime:    targetTime,
		Status:      0,
	}

	err = db.Where("title = ?", "2026年度回馈大抽奖").FirstOrCreate(&event).Error

	if err != nil {
		log.Fatal("创建抽奖活动失败:", err)
	}

	log.Println("测试抽奖活动已更新为 B站大会员一个月！")
}
