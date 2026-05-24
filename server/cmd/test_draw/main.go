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
	"shenliyuan/internal/tasks"
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

	// 1. 创建一个测试用户
	testUser := models.User{
		StudentID: "test_lottery_user",
		Nickname: "测试小明",
		Role:     "user",
		Exp:      500, // 给他一点经验增加权重
	}
	// 避免重复运行报错，先尝试查找
	if err := db.Where("student_id = ?", "test_lottery_user").FirstOrCreate(&testUser).Error; err != nil {
		log.Fatal("创建测试用户失败:", err)
	}

	// 2. 创建一个测试抽奖活动
	event := models.LotteryEvent{
		Title:       "公告测试专用抽奖",
		Description: "这是一个为了测试公告效果而生成的自动抽奖",
		PrizeName:   "测试大奖（一台保时捷）",
		DrawTime:    time.Now().Add(-1 * time.Hour), // 故意设置在过去，假装到期了
		Status:      0,
	}
	if err := db.Create(&event).Error; err != nil {
		log.Fatal("创建测试抽奖活动失败:", err)
	}

	// 3. 让测试用户参与这个抽奖
	participant := models.LotteryParticipant{
		LotteryID: event.ID,
		UserID:    testUser.ID,
		Weight:    1 + (testUser.Exp / 10),
	}
	if err := db.Create(&participant).Error; err != nil {
		log.Fatal("创建参与记录失败:", err)
	}

	// 4. 调用我们的自动开奖核心逻辑
	log.Println("正在执行自动开奖逻辑...")
	if err := tasks.ExecuteDraw(db, event.ID); err != nil {
		log.Fatal("开奖失败:", err)
	}

	log.Println("开奖完成！请在客户端打开【系统公告】查看生成的公告内容！")
}
