package tasks

import (
	"context"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

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
		if requiredVotes < models.AppealMinRequiredVotes {
			requiredVotes = models.AppealMinRequiredVotes
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
			// 与立即结案共用同一条原子扣减实现（见 models/appeal_exp.go）。
			if err := models.PenalizeAdminExpOnAppealPass(tx, appeal.AdminID); err != nil {
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
			resultMessage = "社区评议未形成有效裁决，案件已转交独立管理员复核，请等待最终结果。"
			notificationType = models.NotificationTypeAppealReviewRequired
			notificationKey = "appeal-review-required"
		}
		if err := createAppealAppellantNotification(tx, appeal, false); err != nil {
			return err
		}
		if appeal.Status == models.AppealStatusReview {
			if err := createAppealReviewNotifications(tx, appeal.ID, appeal.AdminID); err != nil {
				return err
			}
		} else if err := createAppealTaskNotification(tx, appeal.AdminID, appeal.ID, notificationType,
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
		if err := tx.Model(&models.Post{}).Where("id = ?", appeal.PostID).Updates(map[string]interface{}{
			"status":               originalStatus,
			"moderation_rule_code": "",
			"moderation_reason":   "",
		}).Error; err != nil {
			return err
		}
		var rows []models.PostImage
		if err := tx.Select("file_id").Where("post_id = ?", appeal.PostID).Find(&rows).Error; err == nil && len(rows) > 0 {
			fileIDs := make([]uint, 0, len(rows))
			for _, r := range rows {
				fileIDs = append(fileIDs, r.FileID)
			}
			if err := services.ReconcileFilePublicAccess(tx, fileIDs...); err != nil {
				return err
			}
		}
		now := time.Now()
		if err := tx.Model(&models.PostRectificationReview{}).
			Where("post_id = ? AND status = ?", appeal.PostID, models.RectificationReviewPending).
			Updates(map[string]interface{}{
				"status":        models.RectificationReviewApproved,
				"review_reason": "申诉通过自动解除治理并归档整改复审",
				"reviewed_at":   &now,
			}).Error; err != nil {
			return err
		}
	}
	if appeal.ReportID == nil {
		return nil
	}
	var report models.Report
	if err := tx.First(&report, *appeal.ReportID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
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
	return db.Clauses(clause.OnConflict{DoNothing: true}).Create(&models.Notification{
		UserID: userID, Type: notificationType, RelatedID: appealID, Content: content, DedupKey: dedupKey,
	}).Error
}

// createAppealAppellantNotification 写申诉人的主通知。
//
// 与 handlers 侧共用 models.ResolveAppealAppellantNotification，保证「投票即时结案」
// 与「到期兜底结案」对同一个结案事件给出同一条通知：类型一致、数量一致、挂载维度
// 一致（帖子类挂 PostID 让客户端直达帖子治理结果区）。
func createAppealAppellantNotification(db *gorm.DB, appeal models.Appeal, closedByHumanReview bool) error {
	notification := models.ResolveAppealAppellantNotification(appeal, closedByHumanReview)
	if !notification.PostScoped {
		return createAppealTaskNotification(db, appeal.AppellantID, appeal.ID,
			notification.Type, notification.Content, notification.DedupKey)
	}
	if appeal.AppellantID == 0 || appeal.PostID == 0 {
		return nil
	}
	return db.Clauses(clause.OnConflict{DoNothing: true}).Create(&models.Notification{
		UserID: appeal.AppellantID, Type: notification.Type, PostID: appeal.PostID,
		Content: notification.Content, DedupKey: notification.DedupKey,
	}).Error
}

// createAppealReviewNotifications 只把人工复核待办发给排除原治理管理员后的管理员。
func createAppealReviewNotifications(db *gorm.DB, appealID, originalAdminID uint) error {
	var reviewerIDs []uint
	if err := db.Model(&models.User{}).
		Where("id <> ? AND role IN ?", originalAdminID, []models.Role{models.RoleAdmin, models.RoleSuperAdmin}).
		Pluck("id", &reviewerIDs).Error; err != nil {
		return err
	}
	if len(reviewerIDs) == 0 {
		return createAppealTaskNotification(db, originalAdminID, appealID, models.NotificationTypeAppealReviewRequired,
			"当前暂无可用的独立复核管理员，案件已进入待分配复核队列。", fmt.Sprintf("appeal-review-required:%d:waiting", appealID))
	}
	if err := createAppealTaskNotification(db, originalAdminID, appealID, models.NotificationTypeAppealReviewRequired,
		"该案件已转交其他管理员复核，你无需处理。", fmt.Sprintf("appeal-review-required:%d:original-admin", appealID)); err != nil {
		return err
	}
	for _, reviewerID := range reviewerIDs {
		if err := createAppealTaskNotification(db, reviewerID, appealID, models.NotificationTypeAppealReviewRequired,
			"有公众法庭案件待人工复核，请查看法庭复核待办。", fmt.Sprintf("appeal-review-required:%d:reviewer:%d", appealID, reviewerID)); err != nil {
			return err
		}
	}
	return nil
}
