package services

import (
	"fmt"
	"strings"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
)

// CourseEvaluationNotificationTitle 通知标题。
const CourseEvaluationNotificationTitle = "学科评价审核结果"

// courseEvaluationNotificationContent 生成面向用户的通知摘要。
func courseEvaluationNotificationContent(submission *models.CourseEvaluationSubmission, status string) string {
	target := submission.CourseName
	if submission.TeacherName != "" {
		target = fmt.Sprintf("%s · %s", submission.CourseName, submission.TeacherName)
	}
	switch status {
	case models.CourseEvaluationStatusPublished:
		return fmt.Sprintf("你提交的「%s」评价已通过审核并发布", target)
	case models.CourseEvaluationStatusNeedsEdit:
		reason := strings.TrimSpace(submission.ReviewReason)
		if reason == "" {
			reason = "请修改后重新提交"
		}
		return fmt.Sprintf("你提交的「%s」评价需要修改：%s", target, reason)
	default:
		return fmt.Sprintf("你提交的「%s」评价状态已更新", target)
	}
}

// CourseEvaluationNotificationDedupKey 审核结果通知去重键。
// 包含提交 ID、revision 与状态，保证同一 revision 的重复审核只产生一条通知。
func CourseEvaluationNotificationDedupKey(submissionID uint, revision int, status string) string {
	return fmt.Sprintf("course_evaluation_result:%d:%d:%s", submissionID, revision, status)
}

// writeCourseEvaluationNotification 在审核事务内写入幂等通知。
//
// 约定：type = course_evaluation_result，RelatedID = 提交 ID，PostID = 0，FromUID = 0。
// 客户端必须按 related_id 深链到"个人中心 → 我的内容 → 学科评价"，
// 不得把 related_id 当作帖子 ID 使用。
//
// 去重方式与既有组队通知保持一致：先按 (user_id, type, dedup_key) 计数再写入，
// 依赖调用方所在事务保证原子性。
func writeCourseEvaluationNotification(tx *gorm.DB, submission *models.CourseEvaluationSubmission, status string) error {
	if tx == nil || submission == nil || submission.UserID == 0 {
		return nil
	}
	dedupKey := CourseEvaluationNotificationDedupKey(submission.ID, submission.Revision, status)
	var count int64
	if err := tx.Model(&models.Notification{}).
		Where("user_id = ? AND type = ? AND dedup_key = ?",
			submission.UserID, models.NotificationTypeCourseEvaluationResult, dedupKey).
		Count(&count).Error; err != nil {
		// 通知失败不应阻断审核主流程。
		return nil
	}
	if count > 0 {
		return nil
	}
	// 通知字段刻意置零：该类型不关联帖子，避免客户端误走帖子深链。
	tx.Create(&models.Notification{
		UserID:    submission.UserID,
		Type:      models.NotificationTypeCourseEvaluationResult,
		Content:   courseEvaluationNotificationContent(submission, status),
		RelatedID: submission.ID,
		DedupKey:  dedupKey,
		PostID:    0,
		FromUID:   0,
	})
	return nil
}
