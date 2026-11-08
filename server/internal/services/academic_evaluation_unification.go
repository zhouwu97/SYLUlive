package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
)

type AcademicUnificationOptions struct {
	Apply           bool
	BackupConfirmed bool
	ExpectedPlan    string
}

type AcademicUnificationConflict struct {
	RatingID uint   `json:"rating_id"`
	Reason   string `json:"reason"`
}

// 报告只包含数量、记录 ID 与指纹，不输出个人评价正文。
type AcademicUnificationReport struct {
	Total          int                           `json:"total"`
	AlreadyUnified int                           `json:"already_unified"`
	Create         int                           `json:"create"`
	Repair         int                           `json:"repair"`
	Fingerprint    string                        `json:"fingerprint"`
	Applied        bool                          `json:"applied"`
	Conflicts      []AcademicUnificationConflict `json:"conflicts"`
}

type academicUnificationAction struct {
	rating     models.TeacherRating
	submission models.CourseEvaluationSubmission
	create     bool
}

// UnifyAcademicEvaluations 将历史公开评价登记到唯一主记录。
// 默认只读预览；写入前在同一事务中重算指纹，任一冲突都会阻止整批修改。
func UnifyAcademicEvaluations(ctx context.Context, db *gorm.DB, options AcademicUnificationOptions) (*AcademicUnificationReport, error) {
	report := &AcademicUnificationReport{Conflicts: []AcademicUnificationConflict{}}
	if db == nil {
		return report, errors.New("database is nil")
	}
	if options.Apply && (!options.BackupConfirmed || options.ExpectedPlan == "") {
		return report, errors.New("执行迁移必须确认备份并提供只读预览指纹")
	}
	err := db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if options.Apply && tx.Dialector.Name() == "postgres" {
			if err := tx.Exec("SET LOCAL lock_timeout = '5s'").Error; err != nil {
				return err
			}
			if err := tx.Exec("LOCK TABLE teachers, teacher_ratings, course_evaluation_submissions IN SHARE ROW EXCLUSIVE MODE").Error; err != nil {
				return err
			}
		}
		var ratings []models.TeacherRating
		if err := tx.Order("id ASC").Find(&ratings).Error; err != nil {
			return err
		}
		report.Total = len(ratings)
		hash := sha256.New()
		actions := []academicUnificationAction{}
		planned := map[string]uint{}
		conflict := func(id uint, reason string) {
			report.Conflicts = append(report.Conflicts, AcademicUnificationConflict{RatingID: id, Reason: reason})
		}
		for _, rating := range ratings {
			var teacher models.Teacher
			if err := tx.First(&teacher, rating.TeacherID).Error; err != nil {
				if errors.Is(err, gorm.ErrRecordNotFound) {
					conflict(rating.ID, "teacher_not_found")
					continue
				}
				return err
			}
			key := models.CourseEvaluationDedupKey(rating.UserID, teacher.Course, teacher.Name)
			if models.NormalizeCourseSubjectName(teacher.Course) == "" || models.NormalizeTeacherName(teacher.Name) == "" {
				conflict(rating.ID, "invalid_target_name")
				continue
			}
			var candidates []models.CourseEvaluationSubmission
			query := tx.Where("teacher_rating_id = ?", rating.ID)
			if rating.CourseEvaluationSubmissionID != nil {
				query = query.Or("id = ?", *rating.CourseEvaluationSubmissionID)
			}
			if err := query.Order("id ASC").Find(&candidates).Error; err != nil {
				return err
			}
			if len(candidates) == 0 {
				if rating.CourseEvaluationSubmissionID != nil {
					conflict(rating.ID, "missing_linked_master")
					continue
				}
				if err := tx.Where("user_id = ? AND dedup_key = ?", rating.UserID, key).Find(&candidates).Error; err != nil {
					return err
				}
			}
			if len(candidates) > 1 {
				conflict(rating.ID, "multiple_linked_masters")
				continue
			}
			var master models.CourseEvaluationSubmission
			if len(candidates) == 1 {
				master = candidates[0]
			}
			snapshot, err := json.Marshal([]interface{}{rating, teacher, master})
			if err != nil {
				return err
			}
			_, _ = hash.Write(snapshot)
			if master.ID != 0 {
				if master.UserID != rating.UserID || (master.TeacherID != nil && *master.TeacherID != rating.TeacherID) || (master.TeacherID == nil && master.DedupKey != key) {
					conflict(rating.ID, "owner_or_teacher_mismatch")
					continue
				}
				if master.TeacherRatingID != nil && *master.TeacherRatingID != rating.ID {
					conflict(rating.ID, "master_has_another_projection")
					continue
				}
				if master.Status != models.CourseEvaluationStatusPublished || master.Star != rating.Star || master.Comment != rating.Comment {
					conflict(rating.ID, "content_or_workflow_conflict")
					continue
				}
				if master.TeacherRatingID != nil && rating.CourseEvaluationSubmissionID != nil && *rating.CourseEvaluationSubmissionID == master.ID {
					report.AlreadyUnified++
					continue
				}
				report.Repair++
			} else {
				if rating.UserID == 0 || rating.Star < 1 || rating.Star > 5 || rating.CreatedAt.IsZero() || rating.UpdatedAt.IsZero() {
					conflict(rating.ID, "invalid_legacy_record")
					continue
				}
				if first, exists := planned[key]; exists {
					conflict(first, "duplicate_legacy_target")
					conflict(rating.ID, "duplicate_legacy_target")
					continue
				}
				planned[key] = rating.ID
				teacherID, ratingID := teacher.ID, rating.ID
				master = models.CourseEvaluationSubmission{
					UserID: rating.UserID, DedupKey: key, Source: models.CourseEvaluationSourceLegacyTeacher,
					CourseName: teacher.Course, TeacherName: teacher.Name, TeacherID: &teacherID,
					CourseSubjectID: teacher.CourseSubjectID, Star: rating.Star, Comment: rating.Comment,
					Status: models.CourseEvaluationStatusPublished, Revision: 1, TeacherRatingID: &ratingID,
					CreatedAt: rating.CreatedAt, UpdatedAt: rating.UpdatedAt,
				}
				report.Create++
			}
			actions = append(actions, academicUnificationAction{rating: rating, submission: master, create: master.ID == 0})
		}
		report.Fingerprint = hex.EncodeToString(hash.Sum(nil))
		if len(report.Conflicts) != 0 {
			return fmt.Errorf("存在 %d 项历史关联或内容冲突，未写入任何记录", len(report.Conflicts))
		}
		if !options.Apply {
			return nil
		}
		if options.ExpectedPlan != report.Fingerprint {
			return errors.New("数据已变化，请重新预览迁移计划")
		}
		for _, action := range actions {
			master := action.submission
			if action.create {
				if err := tx.Create(&master).Error; err != nil {
					return err
				}
			} else if err := tx.Model(&models.CourseEvaluationSubmission{}).
				Where("id = ? AND user_id = ?", master.ID, action.rating.UserID).
				UpdateColumn("teacher_rating_id", action.rating.ID).Error; err != nil {
				return err
			}
			if err := tx.Model(&models.TeacherRating{}).Where("id = ? AND user_id = ?", action.rating.ID, action.rating.UserID).
				UpdateColumn("course_evaluation_submission_id", master.ID).Error; err != nil {
				return err
			}
		}
		report.Applied = true
		return nil
	})
	if err != nil {
		report.Applied = false
	}
	return report, err
}

// DeleteTeacherEvaluation 保留旧公开 ID 的兼容入口，删除同一份本人评价。
// 所有权检查先于任何关联修改；主记录和公开投影在同一事务中删除。
func (s *CourseEvaluationService) DeleteTeacherEvaluation(userID, ratingID uint) error {
	if s == nil || s.db == nil {
		return courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "评价服务不可用", nil)
	}
	if userID == 0 || ratingID == 0 {
		return courseEvalErr(CodeCourseEvaluationForbidden, "无权删除", nil)
	}
	err := s.db.Transaction(func(tx *gorm.DB) error {
		var original models.TeacherRating
		if err := tx.Unscoped().Where("id = ? AND user_id = ?", ratingID, userID).First(&original).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return courseEvalErr(CodeCourseEvaluationForbidden, "无权删除", nil)
			}
			return err
		}
		if original.DeletedAt.Valid {
			return nil
		}
		var masters []models.CourseEvaluationSubmission
		query := tx.Where("teacher_rating_id = ?", ratingID)
		if original.CourseEvaluationSubmissionID != nil {
			query = query.Or("id = ?", *original.CourseEvaluationSubmissionID)
		}
		if err := query.Clauses(clause.Locking{Strength: "UPDATE"}).Find(&masters).Error; err != nil {
			return err
		}
		if len(masters) > 1 {
			return courseEvalErr(CodeCourseEvaluationConflict, "评价关联异常，请刷新后重试", nil)
		}
		for _, master := range masters {
			if master.UserID != userID || (master.TeacherRatingID != nil && *master.TeacherRatingID != ratingID) ||
				(master.TeacherID != nil && *master.TeacherID != original.TeacherID) {
				return courseEvalErr(CodeCourseEvaluationConflict, "评价关联异常，请刷新后重试", nil)
			}
		}
		var current models.TeacherRating
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND user_id = ?", ratingID, userID).First(&current).Error; err != nil {
			return err
		}
		if !sameUintPtr(current.CourseEvaluationSubmissionID, original.CourseEvaluationSubmissionID) {
			return courseEvalErr(CodeCourseEvaluationConflict, "评价已更新，请刷新后重试", nil)
		}
		if err := tx.Model(&current).UpdateColumn("course_evaluation_submission_id", nil).Error; err != nil {
			return err
		}
		if err := tx.Delete(&current).Error; err != nil {
			return err
		}
		for _, master := range masters {
			if err := tx.Model(&models.CourseEvaluationSubmission{}).Where("superseded_by_submission_id = ?", master.ID).
				UpdateColumn("superseded_by_submission_id", nil).Error; err != nil {
				return err
			}
			if err := tx.Delete(&master).Error; err != nil {
				return err
			}
		}
		return nil
	})
	return mapCourseEvalTxError(err)
}
