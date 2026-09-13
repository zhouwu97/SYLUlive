package tasks

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const appealFinalizerInterval = time.Minute

// AppealFinalizerCron 让到期案件即使无人继续投票也能进入确定状态。
type AppealFinalizerCron struct {
	wg sync.WaitGroup
}

func (c *AppealFinalizerCron) Wait() {
	if c != nil {
		c.wg.Wait()
	}
}

func StartAppealFinalizerCron(ctx context.Context, db *gorm.DB) *AppealFinalizerCron {
	cron := &AppealFinalizerCron{}
	if db == nil {
		return cron
	}
	cron.wg.Add(1)
	go func() {
		defer cron.wg.Done()
		run := func() {
			count, err := FinalizeExpiredAppeals(db, time.Now())
			if err != nil {
				log.Printf("申诉超时结案失败: %v", err)
			} else if count > 0 {
				log.Printf("申诉超时结案完成: finalized=%d", count)
			}
		}
		run()
		ticker := time.NewTicker(appealFinalizerInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				run()
			}
		}
	}()
	return cron
}

// FinalizeExpiredAppeals 批量处理已过投票截止时间的 pending 案件。
func FinalizeExpiredAppeals(db *gorm.DB, now time.Time) (int, error) {
	var ids []uint
	if err := db.Model(&models.Appeal{}).
		Where("status = ? AND voting_deadline IS NOT NULL AND voting_deadline <= ?", models.AppealStatusPending, now).
		Limit(100).Pluck("id", &ids).Error; err != nil {
		return 0, err
	}
	finalized := 0
	for _, id := range ids {
		changed, err := finalizeExpiredAppeal(db, id, now)
		if err != nil {
			return finalized, err
		}
		if changed {
			finalized++
		}
	}
	return finalized, nil
}

func finalizeExpiredAppeal(db *gorm.DB, appealID uint, now time.Time) (bool, error) {
	changed := false
	err := db.Transaction(func(tx *gorm.DB) error {
		var appeal models.Appeal
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&appeal, appealID).Error; err != nil {
			return err
		}
		if appeal.Status != models.AppealStatusPending || appeal.VotingDeadline == nil || appeal.VotingDeadline.After(now) {
			return nil
		}

		var votes []models.AppealVote
		if err := tx.Where("appeal_id = ?", appealID).Find(&votes).Error; err != nil {
			return err
		}
		supportCount, opposeCount := 0, 0
		for _, vote := range votes {
			switch vote.Vote {
			case "support":
				supportCount++
			case "oppose":
				opposeCount++
			}
		}

		appeal.ClosedAt = &now
		appeal.ClosedReason = "voting_deadline_reached"
		if supportCount == opposeCount {
			appeal.Status = models.AppealStatusReview
			appeal.Result = fmt.Sprintf("支持票: %d, 反对票: %d, 平票，转人工复核", supportCount, opposeCount)
		} else if supportCount > opposeCount {
			appeal.Status = models.AppealStatusPass
			appeal.Result = fmt.Sprintf("支持票: %d, 反对票: %d, 申诉成功", supportCount, opposeCount)
			if err := tx.Model(&models.Post{}).Where("id = ?", appeal.PostID).Update("status", models.PostStatusNormal).Error; err != nil {
				return err
			}
			if err := tx.Model(&models.User{}).Where("id = ?", appeal.AdminID).
				Update("admin_exp", gorm.Expr("CASE WHEN admin_exp >= 3 THEN admin_exp - 3 ELSE 0 END")).Error; err != nil {
				return err
			}
		} else {
			appeal.Status = models.AppealStatusReject
			appeal.Result = fmt.Sprintf("支持票: %d, 反对票: %d, 申诉失败", supportCount, opposeCount)
			if err := tx.Model(&models.User{}).Where("id = ?", appeal.AdminID).
				Update("admin_exp", gorm.Expr("admin_exp + 5")).Error; err != nil {
				return err
			}
		}
		changed = true
		return tx.Save(&appeal).Error
	})
	return changed, err
}
