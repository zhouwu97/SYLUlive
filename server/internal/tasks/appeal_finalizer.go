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
	if err := notifyUpcomingAppeals(db, now); err != nil {
		return 0, err
	}
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

		requiredVotes := appeal.RequiredVotes
		if requiredVotes < 5 {
			requiredVotes = 5
		}
		if supportCount+opposeCount < requiredVotes {
			appeal.Status = models.AppealStatusReview
			appeal.Result = fmt.Sprintf("仅收到 %d 票，未达到法定人数 %d，转人工复核", supportCount+opposeCount, requiredVotes)
			appeal.ClosedReason = "insufficient_votes"
			appeal.EscalationReason = "insufficient_votes"
		} else if supportCount == opposeCount {
			appeal.Status = models.AppealStatusReview
			appeal.Result = fmt.Sprintf("支持票: %d, 反对票: %d, 平票，转人工复核", supportCount, opposeCount)
			appeal.ClosedReason = "tie_review_required"
			appeal.EscalationReason = "tie"
		} else if supportCount > opposeCount {
			appeal.Status = models.AppealStatusPass
			appeal.Result = fmt.Sprintf("支持票: %d, 反对票: %d, 申诉成功", supportCount, opposeCount)
			appeal.ClosedAt = &now
			appeal.ClosedReason = "voting_deadline_reached"
			if err := applyAppealPass(tx, appeal); err != nil {
				return err
			}
			if err := tx.Model(&models.User{}).Where("id = ?", appeal.AdminID).
				Update("admin_exp", gorm.Expr("CASE WHEN admin_exp >= 3 THEN admin_exp - 3 ELSE 0 END")).Error; err != nil {
				return err
			}
		} else {
			appeal.Status = models.AppealStatusReject
			appeal.Result = fmt.Sprintf("支持票: %d, 反对票: %d, 申诉失败", supportCount, opposeCount)
			appeal.ClosedAt = &now
			appeal.ClosedReason = "voting_deadline_reached"
			if err := tx.Model(&models.User{}).Where("id = ?", appeal.AdminID).
				Update("admin_exp", gorm.Expr("admin_exp + 5")).Error; err != nil {
				return err
			}
		}
		changed = true
		resultMessage := "公众法庭案件已结案，请查看复核结果。"
		notificationType := models.NotificationTypeAppealResult
		notificationKey := "appeal-result"
		if appeal.Status == models.AppealStatusReview {
			resultMessage = "社区评议未形成有效裁决，案件已转人工复核，请等待管理员处理。"
			notificationType = models.NotificationTypeAppealReviewRequired
			notificationKey = "appeal-review-required"
		}
		if err := createAppealTaskNotification(tx, appeal.AppellantID, appeal.ID, notificationType,
			resultMessage, fmt.Sprintf("%s:%d:appellant", notificationKey, appeal.ID)); err != nil {
			return err
		}
		if err := createAppealTaskNotification(tx, appeal.AdminID, appeal.ID, notificationType,
			resultMessage, fmt.Sprintf("%s:%d:admin", notificationKey, appeal.ID)); err != nil {
			return err
		}
		if appeal.Status == models.AppealStatusPass || appeal.Status == models.AppealStatusReject {
			for _, vote := range votes {
				if vote.Recused {
					continue
				}
				if err := createAppealTaskNotification(tx, vote.VoterID, appeal.ID, models.NotificationTypeAppealResult,
					resultMessage, fmt.Sprintf("appeal-result:%d:jury:%d", appeal.ID, vote.VoterID)); err != nil {
					return err
				}
			}
		}
		return tx.Save(&appeal).Error
	})
	return changed, err
}

// applyAppealPass 恢复治理前状态，并撤销原举报造成的信誉计数。
func applyAppealPass(tx *gorm.DB, appeal models.Appeal) error {
	if appeal.TargetType == "reply" {
		originalStatus := appeal.OriginalTargetStatus
		if originalStatus == "" {
			originalStatus = string(models.ReplyStatusNormal)
		}
		if err := tx.Model(&models.Reply{}).Where("id = ?", appeal.TargetID).Update("status", originalStatus).Error; err != nil {
			return err
		}
		var replyCount int64
		if err := tx.Model(&models.Reply{}).Where("post_id = ? AND status = ?", appeal.PostID, models.ReplyStatusNormal).Count(&replyCount).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.Post{}).Where("id = ?", appeal.PostID).Update("reply_count", replyCount).Error; err != nil {
			return err
		}
	} else {
		originalStatus := appeal.OriginalPostStatus
		if originalStatus == "" {
			originalStatus = models.PostStatusNormal
		}
		if err := tx.Model(&models.Post{}).Where("id = ?", appeal.PostID).Update("status", originalStatus).Error; err != nil {
			return err
		}
	}
	if appeal.ReportID == nil {
		return nil
	}
	var report models.Report
	if err := tx.First(&report, *appeal.ReportID).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			return nil
		}
		return err
	}
	if report.Status != models.ReportStatusHandled {
		return nil
	}
	if err := tx.Model(&report).Updates(map[string]interface{}{"status": models.ReportStatusOverturned, "result": "申诉通过，撤销原治理决定"}).Error; err != nil {
		return err
	}
	if report.TargetAuthorID != nil {
		return tx.Model(&models.User{}).Where("id = ?", *report.TargetAuthorID).
			Update("report_count", gorm.Expr("CASE WHEN report_count > 0 THEN report_count - 1 ELSE 0 END")).Error
	}
	return nil
}

func notifyUpcomingAppeals(db *gorm.DB, now time.Time) error {
	deadline := now.Add(24 * time.Hour)
	var appeals []models.Appeal
	if err := db.Where("status = ? AND voting_deadline > ? AND voting_deadline <= ?", models.AppealStatusPending, now, deadline).Find(&appeals).Error; err != nil {
		return err
	}
	for _, appeal := range appeals {
		var jury []models.AppealVote
		if err := db.Where("appeal_id = ? AND vote = '' AND recused = ?", appeal.ID, false).Find(&jury).Error; err != nil {
			return err
		}
		for _, vote := range jury {
			if err := createAppealTaskNotification(db, vote.VoterID, appeal.ID, models.NotificationTypeAppealDeadline,
				"公众法庭案件将在 24 小时内截止，请及时完成评议。", fmt.Sprintf("appeal-deadline:%d:%d", appeal.ID, vote.VoterID)); err != nil {
				return err
			}
		}
	}
	return nil
}

func createAppealTaskNotification(db *gorm.DB, userID, appealID uint, notificationType, content, dedupKey string) error {
	if userID == 0 || appealID == 0 {
		return nil
	}
	var existing models.Notification
	if err := db.Where("user_id = ? AND type = ? AND dedup_key = ?", userID, notificationType, dedupKey).First(&existing).Error; err == nil {
		return nil
	}
	err := db.Create(&models.Notification{UserID: userID, Type: notificationType, RelatedID: appealID, Content: content, DedupKey: dedupKey}).Error
	if err != nil {
		if lookupErr := db.Where("user_id = ? AND type = ? AND dedup_key = ?", userID, notificationType, dedupKey).First(&existing).Error; lookupErr == nil {
			return nil
		}
	}
	return err
}
