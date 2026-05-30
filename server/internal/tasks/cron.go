package tasks

import (
	"crypto/rand"
	"fmt"
	"log"
	"math/big"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// StartLotteryCron 启动抽奖自动开奖轮询任务
func StartLotteryCron(db *gorm.DB) {
	ticker := time.NewTicker(1 * time.Minute)
	go func() {
		for range ticker.C {
			checkAndDrawLotteries(db)
		}
	}()
	log.Println("Lottery Cron Daemon started.")
}

func checkAndDrawLotteries(db *gorm.DB) {
	var events []models.LotteryEvent
	now := time.Now()

	// 查找所有未开奖且已到期的活动
	err := db.Where("status = ? AND draw_time <= ?", 0, now).Find(&events).Error
	if err != nil {
		log.Printf("检查自动开奖失败: %v\n", err)
		return
	}

	for _, event := range events {
		log.Printf("活动 [%s] 达到开奖时间，准备开奖...", event.Title)
		ExecuteDraw(db, event.ID)
	}
}

// ExecuteDraw 独立出来的开奖逻辑，用于定时任务或管理员手动触发
func ExecuteDraw(db *gorm.DB, eventID uint) error {
	var event models.LotteryEvent
	if err := db.First(&event, eventID).Error; err != nil {
		return err
	}

	if event.Status == 1 {
		return fmt.Errorf("该活动已经开过奖了")
	}

	var participants []models.LotteryParticipant
	db.Where("lottery_id = ?", event.ID).Find(&participants)

	if len(participants) == 0 {
		// 没有人参与，可以视为流拍，或者直接标记为已结束
		db.Model(&event).Update("status", 1)
		log.Printf("活动 [%s] 无人参与，自动流拍。\n", event.Title)
		return nil
	}

	var totalWeight int64
	for _, p := range participants {
		totalWeight += int64(p.Weight)
	}

	// 密码学级公平摇号
	n, err := rand.Int(rand.Reader, big.NewInt(totalWeight))
	if err != nil {
		return fmt.Errorf("生成安全随机数失败: %v", err)
	}

	randomTarget := n.Int64()
	var winnerID uint
	var currentSum int64

	for _, p := range participants {
		currentSum += int64(p.Weight)
		if currentSum > randomTarget {
			winnerID = p.UserID
			break
		}
	}

	// 执行事务：更新状态、发通知、发公告
	err = db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&event).Updates(map[string]interface{}{
			"status":    1,
			"winner_id": winnerID,
		}).Error; err != nil {
			return err
		}

		// 1. 找到中奖者信息用于公告
		var winner models.User
		if err := tx.First(&winner, winnerID).Error; err != nil {
			return err
		}

		// 2. 寻找或创建“系统自动发出”虚拟账号
		var sysUser models.User
		errSys := tx.Where("nickname = ?", "系统自动发出").First(&sysUser).Error
		if errSys != nil {
			// 如果不存在，创建这个虚拟账号
			sysUser = models.User{
				Nickname: "系统自动发出",
				StudentID: "system_auto",
				Role:     "admin",
			}
			if err := tx.Create(&sysUser).Error; err != nil {
				return err
			}
		}

		// 3. 创建全服系统公告
		announcementContent := fmt.Sprintf(
			"本次抽奖已于 %s 准时由系统自动开出！\n\n经过公平的底层真随机算法与经验值加权计算，恭喜用户【%s】幸运地抽中了【%s】！\n\n（本系统抽奖权重规则：基础权重1 + 经验值/10，完全公平公正，欢迎大家踊跃在社区活跃！）",
			time.Now().Format("2006-01-02 15:04"),
			winner.Nickname,
			event.PrizeName,
		)
		
		ann := models.Announcement{
			Title:     fmt.Sprintf("🎉 【%s】自动开奖结果公示！", event.Title),
			Content:   announcementContent,
			CreatedBy: sysUser.ID,
			IsPinned:  false,
		}
		
		if err := tx.Create(&ann).Error; err != nil {
			return err
		}

		return nil
	})

	if err != nil {
		log.Printf("开奖事务执行失败: %v\n", err)
		return err
	}

	log.Printf("活动 [%s] 成功开奖！中奖者ID: %d\n", event.Title, winnerID)
	return nil
}
