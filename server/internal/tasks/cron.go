package tasks

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log"
	"math/big"
	"sync"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

var ErrLotteryAlreadyDrawn = errors.New("lottery already drawn")

const (
	examPaperStorageJobInterval         = time.Minute
	examPaperStorageMaintenanceInterval = 24 * time.Hour
	examPaperStorageMaintenanceTimeout  = 30 * time.Minute
	examPaperStorageJobBatchSize        = 50
	eduCredentialCleanupJobInterval     = time.Minute
	eduCredentialCleanupJobBatchSize    = 50
	eduBindingRecoveryInterval          = time.Minute
	eduBindingRecoveryBatchSize         = 50
	idempotencyCleanupInterval          = 6 * time.Hour
	idempotencyCleanupBatchSize         = 500
)

type examPaperStorageJobProcessor interface {
	ProcessDue(context.Context, int) (services.ExamPaperStorageJobProcessReport, error)
}

type examPaperStorageMaintainer interface {
	Run(context.Context) (services.ExamPaperStorageMaintenanceReport, error)
}

type eduCredentialCleanupJobProcessor interface {
	ProcessDue(context.Context, int) (services.EduCredentialCleanupJobProcessReport, error)
}

type eduBindingRecoveryProcessor interface {
	ProcessDue(context.Context, int) (services.EduBindingRecoveryReport, error)
}

// ExamPaperStorageCron 持有存储后台任务的退出同步状态。
type ExamPaperStorageCron struct {
	wg sync.WaitGroup
}

// EduCredentialCleanupCron 持有教务凭证清理任务的退出同步状态。
type EduCredentialCleanupCron struct {
	wg sync.WaitGroup
}

// EduBindingRecoveryCron 持有跨服务教务绑定恢复任务的退出同步状态。
type EduBindingRecoveryCron struct {
	wg sync.WaitGroup
}

// IdempotencyCleanupCron 负责幂等响应缓存的有限批量回收。
type IdempotencyCleanupCron struct {
	wg sync.WaitGroup
}

// Wait 等待教务凭证清理任务在 context 取消后退出。
func (c *EduCredentialCleanupCron) Wait() {
	if c != nil {
		c.wg.Wait()
	}
}

// Wait 等待教务绑定恢复任务在 context 取消后退出。
func (c *EduBindingRecoveryCron) Wait() {
	if c != nil {
		c.wg.Wait()
	}
}

// Wait 等待所有存储后台任务在 context 取消后退出。
func (c *ExamPaperStorageCron) Wait() {
	if c != nil {
		c.wg.Wait()
	}
}

// Wait 等待幂等记录清理任务退出。
func (c *IdempotencyCleanupCron) Wait() {
	if c != nil {
		c.wg.Wait()
	}
}

// StartIdempotencyCleanupCron 启动幂等记录清理，并在启动时先执行一次。
func StartIdempotencyCleanupCron(ctx context.Context, db *gorm.DB) *IdempotencyCleanupCron {
	cron := &IdempotencyCleanupCron{}
	if db == nil {
		return cron
	}
	cron.wg.Add(1)
	go func() {
		defer cron.wg.Done()
		cleanup := func() {
			deleted, err := models.CleanupExpiredIdempotencyRecords(db, time.Now().UTC(), idempotencyCleanupBatchSize)
			if err != nil {
				log.Printf("清理幂等记录失败: %v", err)
			} else if deleted > 0 {
				log.Printf("幂等记录清理完成: deleted=%d", deleted)
			}
		}
		cleanup()

		ticker := time.NewTicker(idempotencyCleanupInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				cleanup()
			}
		}
	}()
	log.Println("幂等记录清理后台任务已启动")
	return cron
}

// StartExamPaperStorageCron 启动远端文件 outbox 消费与每日完整性维护。
func StartExamPaperStorageCron(ctx context.Context, jobs examPaperStorageJobProcessor, maintenance examPaperStorageMaintainer) *ExamPaperStorageCron {
	cron := &ExamPaperStorageCron{}
	cron.wg.Add(2)
	go func() {
		defer cron.wg.Done()
		ticker := time.NewTicker(examPaperStorageJobInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}
			report, err := jobs.ProcessDue(ctx, examPaperStorageJobBatchSize)
			if err != nil {
				log.Printf("处理试卷存储任务失败: %v", err)
			} else if report.Processed > 0 {
				log.Printf("试卷存储任务处理完成: processed=%d completed=%d failed=%d", report.Processed, report.Completed, report.Failed)
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	go func() {
		defer cron.wg.Done()
		ticker := time.NewTicker(examPaperStorageMaintenanceInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}
			maintenanceCtx, cancel := context.WithTimeout(ctx, examPaperStorageMaintenanceTimeout)
			report, err := maintenance.Run(maintenanceCtx)
			cancel()
			if err != nil {
				log.Printf("执行试卷存储完整性维护失败: %v", err)
			} else {
				log.Printf("试卷存储完整性维护完成: referenced=%d missing=%d mismatched=%d metadata_errors=%d orphan_removed=%d trash_removed=%d disk_usage=%.2f%%",
					report.Referenced, report.Missing, report.Mismatched, report.MetadataErrors,
					report.OrphanFilesRemoved, report.TrashFilesRemoved, report.DiskUsagePercent)
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	log.Println("试卷远端存储后台任务已启动")
	return cron
}

// StartEduCredentialCleanupCron 启动撤销授权后的教务凭证清理任务。
func StartEduCredentialCleanupCron(ctx context.Context, jobs eduCredentialCleanupJobProcessor) *EduCredentialCleanupCron {
	cron := &EduCredentialCleanupCron{}
	cron.wg.Add(1)
	go func() {
		defer cron.wg.Done()
		ticker := time.NewTicker(eduCredentialCleanupJobInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}
			report, err := jobs.ProcessDue(ctx, eduCredentialCleanupJobBatchSize)
			if err != nil {
				log.Printf("处理教务凭证清理任务失败: %v", err)
			} else if report.Processed > 0 {
				log.Printf("教务凭证清理任务处理完成: processed=%d completed=%d failed=%d", report.Processed, report.Completed, report.Failed)
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	log.Println("教务凭证清理后台任务已启动")
	return cron
}

// StartEduBindingRecoveryCron 启动跨服务绑定崩溃恢复任务。
func StartEduBindingRecoveryCron(ctx context.Context, recovery eduBindingRecoveryProcessor) *EduBindingRecoveryCron {
	cron := &EduBindingRecoveryCron{}
	cron.wg.Add(1)
	go func() {
		defer cron.wg.Done()
		ticker := time.NewTicker(eduBindingRecoveryInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}
			report, err := recovery.ProcessDue(ctx, eduBindingRecoveryBatchSize)
			if err != nil {
				log.Printf("处理教务绑定恢复任务失败: %v", err)
			} else if report.Processed > 0 {
				log.Printf("教务绑定恢复任务完成: processed=%d completed=%d cleaned=%d failed=%d", report.Processed, report.Completed, report.Cleaned, report.Failed)
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	log.Println("教务绑定恢复后台任务已启动")
	return cron
}

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
		if err := ExecuteDraw(db, event.ID); err != nil {
			log.Printf("活动 [%s] 自动开奖失败: %v", event.Title, err)
		}
	}
}

// ExecuteDraw 独立出来的开奖逻辑，用于定时任务或管理员手动触发
func ExecuteDraw(db *gorm.DB, eventID uint) error {
	var event models.LotteryEvent
	if err := db.First(&event, eventID).Error; err != nil {
		return err
	}

	if event.Status == 1 {
		return ErrLotteryAlreadyDrawn
	}

	var participants []models.LotteryParticipant
	if err := db.Where("lottery_id = ?", event.ID).
		Preload("User").
		Find(&participants).Error; err != nil {
		return err
	}

	if len(participants) == 0 {
		// 没有人参与，可以视为流拍，或者直接标记为已结束
		db.Model(&event).Update("status", 1)
		log.Printf("活动 [%s] 无人参与，自动流拍。\n", event.Title)
		return nil
	}

	var totalWeight int64
	for i := range participants {
		currentWeight := services.CalculateLotteryWeightByLevel(participants[i].User.Exp)
		participants[i].Weight = currentWeight
		totalWeight += int64(currentWeight)

		if err := db.Model(&models.LotteryParticipant{}).
			Where("id = ?", participants[i].ID).
			Update("weight", currentWeight).Error; err != nil {
			return err
		}
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
		sysUser, err := services.EnsureSystemUser(tx)
		if err != nil {
			return err
		}

		// 3. 创建全服系统公告
		announcementContent := fmt.Sprintf(
			"本次抽奖已于 %s 准时由系统自动开出！\n\n经过公平的底层真随机算法与经验值加权计算，恭喜用户【%s】幸运地抽中了【%s】！\n\n（本系统抽奖权重规则：用户等级即抽奖权重，Lv.1=1份权重，Lv.8=8份权重；开奖前会按最新等级重新计算。）",
			time.Now().Format("2006-01-02 15:04"),
			winner.Nickname,
			event.PrizeName,
		)

		ann := models.Announcement{
			Title:     fmt.Sprintf("🎉 【%s】自动开奖结果公示！", event.Title),
			Content:   announcementContent,
			CreatedBy: sysUser.ID,
			IsPinned:  true,
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
