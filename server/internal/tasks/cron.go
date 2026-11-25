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
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

var (
	ErrLotteryAlreadyDrawn = errors.New("lottery already drawn")
	ErrLotteryNotReady     = errors.New("lottery draw time not reached")
	beijingLocation        = time.FixedZone("CST", 8*3600)
)

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

// LotteryCron 持有抽奖自动开奖任务的退出同步状态。
type LotteryCron struct {
	wg sync.WaitGroup
}

// Wait 等待抽奖后台任务在 context 取消后退出。
func (c *LotteryCron) Wait() {
	if c != nil {
		c.wg.Wait()
	}
}

// StartLotteryCron 启动抽奖自动开奖轮询任务，启动时立即补偿检查一次，并在 ctx 取消时优雅退出。
func StartLotteryCron(ctx context.Context, db *gorm.DB) *LotteryCron {
	cron := &LotteryCron{}
	if db == nil {
		return cron
	}
	cron.wg.Add(1)
	go func() {
		defer cron.wg.Done()
		checkAndDrawLotteries(db)

		ticker := time.NewTicker(1 * time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				checkAndDrawLotteries(db)
			}
		}
	}()
	log.Println("Lottery Cron Daemon started.")
	return cron
}

func checkAndDrawLotteries(db *gorm.DB) {
	var events []models.LotteryEvent
	now := time.Now()

	// 查找所有未开奖且已到期的活动
	err := db.Where("status = ? AND draw_time <= ?", models.LotteryStatusOngoing, now).Find(&events).Error
	if err != nil {
		log.Printf("检查自动开奖失败: %v\n", err)
		return
	}

	for _, event := range events {
		log.Printf("活动 [%s] 达到开奖时间，准备开奖...", event.Title)
		if err := ExecuteDrawWithMode(db, event.ID, models.LotteryDrawModeAuto); err != nil {
			if errors.Is(err, ErrLotteryAlreadyDrawn) || errors.Is(err, ErrLotteryNotReady) {
				continue
			}
			log.Printf("活动 [%s] 自动开奖失败: %v", event.Title, err)
		}
	}
}

// ExecuteDraw 按自动模式执行开奖逻辑（保持历史调用方兼容）。
func ExecuteDraw(db *gorm.DB, eventID uint) error {
	return ExecuteDrawWithMode(db, eventID, models.LotteryDrawModeAuto)
}

type eligibleLotteryParticipant struct {
	ParticipantID uint
	UserID        uint
	SavedWeight   int
	Nickname      string
	Exp           int
	CurrentWeight int
}

// ExecuteDrawWithMode 在单一事务内加锁并执行开奖，避免定时任务与手动补开并发覆盖或重复发公告。
func ExecuteDrawWithMode(db *gorm.DB, eventID uint, mode string) error {
	if mode != models.LotteryDrawModeManual {
		mode = models.LotteryDrawModeAuto
	}

	var drawnEvent models.LotteryEvent
	var winnerID uint
	var noWinner bool

	err := db.Transaction(func(tx *gorm.DB) error {
		var event models.LotteryEvent
		query := tx
		if tx.Dialector.Name() != "sqlite" {
			query = query.Clauses(clause.Locking{Strength: "UPDATE"})
		}
		if err := query.First(&event, eventID).Error; err != nil {
			return err
		}
		if event.Status != models.LotteryStatusOngoing {
			return ErrLotteryAlreadyDrawn
		}
		if event.DrawTime.After(time.Now()) {
			return ErrLotteryNotReady
		}

		// 只纳入仍存在且处于 active 状态的参与者，剔除已注销或已删除账号。
		var candidates []eligibleLotteryParticipant
		if err := tx.Table("lottery_participants AS lp").
			Select("lp.id AS participant_id, lp.user_id AS user_id, lp.weight AS saved_weight, u.nickname AS nickname, u.exp AS exp").
			Joins("JOIN users AS u ON u.id = lp.user_id").
			Where("lp.lottery_id = ? AND COALESCE(u.account_status, '') IN (?, ?)", event.ID, "", "active").
			Order("lp.id ASC").
			Scan(&candidates).Error; err != nil {
			return err
		}

		now := time.Now()
		if len(candidates) == 0 {
			res := tx.Model(&models.LotteryEvent{}).
				Where("id = ? AND status = ?", event.ID, models.LotteryStatusOngoing).
				Updates(map[string]interface{}{
					"status":    models.LotteryStatusNoWinner,
					"drawn_at":  now,
					"draw_mode": mode,
				})
			if res.Error != nil {
				return res.Error
			}
			if res.RowsAffected == 0 {
				return ErrLotteryAlreadyDrawn
			}
			drawnEvent = event
			noWinner = true
			return nil
		}

		var totalWeight int64
		for i := range candidates {
			currentWeight := services.CalculateLotteryWeightByLevel(candidates[i].Exp)
			candidates[i].CurrentWeight = currentWeight
			totalWeight += int64(currentWeight)

			if candidates[i].SavedWeight != currentWeight {
				if err := tx.Model(&models.LotteryParticipant{}).
					Where("id = ?", candidates[i].ParticipantID).
					Update("weight", currentWeight).Error; err != nil {
					return err
				}
			}
		}

		// 密码学级公平摇号
		n, err := rand.Int(rand.Reader, big.NewInt(totalWeight))
		if err != nil {
			return fmt.Errorf("生成安全随机数失败: %v", err)
		}

		randomTarget := n.Int64()
		var winner eligibleLotteryParticipant
		var currentSum int64
		for _, p := range candidates {
			currentSum += int64(p.CurrentWeight)
			if currentSum > randomTarget {
				winner = p
				break
			}
		}

		res := tx.Model(&models.LotteryEvent{}).
			Where("id = ? AND status = ?", event.ID, models.LotteryStatusOngoing).
			Updates(map[string]interface{}{
				"status":    models.LotteryStatusDrawn,
				"winner_id": winner.UserID,
				"drawn_at":  now,
				"draw_mode": mode,
			})
		if res.Error != nil {
			return res.Error
		}
		if res.RowsAffected == 0 {
			return ErrLotteryAlreadyDrawn
		}

		sysUser, err := services.EnsureSystemUser(tx)
		if err != nil {
			return err
		}

		modeLabel := "系统自动"
		titleSuffix := "自动开奖结果公示！"
		if mode == models.LotteryDrawModeManual {
			modeLabel = "管理员补开"
			titleSuffix = "开奖结果公示！"
		}
		beijingTime := now.In(beijingLocation).Format("2006-01-02 15:04")
		announcementContent := fmt.Sprintf(
			"本次抽奖已于 %s（北京时间）由%s开出！\n\n经过公平的底层真随机算法与等级加权计算，恭喜用户【%s】幸运地抽中了【%s】！\n\n（本系统抽奖权重规则：用户等级即抽奖权重，Lv.1=1份权重，Lv.8=8份权重；开奖前会按最新等级重新计算。）",
			beijingTime,
			modeLabel,
			winner.Nickname,
			event.PrizeName,
		)

		ann := models.Announcement{
			Title:     fmt.Sprintf("🎉 【%s】%s", event.Title, titleSuffix),
			Content:   announcementContent,
			CreatedBy: sysUser.ID,
			IsPinned:  true,
		}
		if err := tx.Create(&ann).Error; err != nil {
			return err
		}

		if tx.Migrator().HasTable(&models.Notification{}) {
			notif := models.Notification{
				UserID:    winner.UserID,
				Type:      models.NotificationTypeLotteryWon,
				Content:   fmt.Sprintf("恭喜你在抽奖活动【%s】中抽中了【%s】！请关注置顶公告联系管理员领奖。", event.Title, event.PrizeName),
				RelatedID: event.ID,
				DedupKey:  fmt.Sprintf("lottery-won:%d:%d", event.ID, winner.UserID),
				FromUID:   sysUser.ID,
			}
			if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&notif).Error; err != nil {
				return err
			}
		}

		drawnEvent = event
		winnerID = winner.UserID
		return nil
	})

	if err != nil {
		if !errors.Is(err, ErrLotteryAlreadyDrawn) && !errors.Is(err, ErrLotteryNotReady) {
			log.Printf("开奖事务执行失败: %v\n", err)
		}
		return err
	}

	if noWinner {
		log.Printf("活动 [%s] 无有效参与者，已标记流拍。\n", drawnEvent.Title)
		return nil
	}

	log.Printf("活动 [%s] 成功开奖！中奖者ID: %d (mode=%s)\n", drawnEvent.Title, winnerID, mode)
	return nil
}
