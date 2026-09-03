package services

import (
	"errors"
	"time"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// Approve 审核通过一条 pending 提交。
//
// 整个审核在一个事务内完成：锁定并校验 pending + revision，
// 创建或复用已审核学科与教师，upsert 教师评价，写审核日志与通知后置 published。
// 唯一索引竞争时重新读取 canonical 行，不向客户端暴露 SQL duplicate 错误。
func (s *CourseEvaluationService) Approve(adminID, submissionID uint, revision int) (*SubmissionView, error) {
	if s == nil || s.db == nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "评价服务不可用", nil)
	}
	if adminID == 0 {
		return nil, courseEvalErr(CodeCourseEvaluationForbidden, "无权审核", nil)
	}

	var view *SubmissionView
	err := s.db.Transaction(func(tx *gorm.DB) error {
		submission, err := lockSubmissionForReview(tx, submissionID)
		if err != nil {
			return err
		}
		// 幂等：同一 revision 已发布时直接返回，不重复写评价与通知。
		if submission.Status == models.CourseEvaluationStatusPublished {
			if submission.Revision == revision {
				view, err = s.toSubmissionView(submission)
				return err
			}
			return courseEvalErr(CodeCourseEvaluationRevisionConflict, "该评价已更新，请刷新后重试", nil)
		}
		if submission.Status != models.CourseEvaluationStatusPending {
			return courseEvalErr(CodeCourseEvaluationNotPending, "该评价不处于待审核状态", nil)
		}
		if submission.Revision != revision {
			return courseEvalErr(CodeCourseEvaluationRevisionConflict, "该评价已被修改，请刷新后重试", nil)
		}

		subject, err := findOrCreateVerifiedSubject(tx, submission)
		if err != nil {
			return err
		}
		teacher, err := findOrCreateVerifiedTeacher(tx, submission, subject, adminID)
		if err != nil {
			return err
		}

		rating, err := upsertTeacherRating(tx, submission.UserID, teacher.ID, submission)
		if err != nil {
			return err
		}

		now := time.Now()
		submission.CourseSubjectID = &subject.ID
		submission.CourseSubjectName = subject.Name
		submission.TeacherID = &teacher.ID
		submission.TeacherRatingID = &rating.ID
		submission.Status = models.CourseEvaluationStatusPublished
		submission.ReviewedBy = &adminID
		submission.ReviewedAt = &now
		submission.ReviewReason = ""
		submission.ProposedCourseName = ""
		submission.ProposedTeacherName = ""
		if err := tx.Save(submission).Error; err != nil {
			return courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "更新评价状态失败", err)
		}

		if err := writeCourseEvaluationAdminLog(tx, adminID, "审核通过课程评价",
			submission.CourseName, submission.TeacherName); err != nil {
			return err
		}
		return writeCourseEvaluationNotification(tx, submission, models.CourseEvaluationStatusPublished)
	})
	if err != nil {
		return nil, err
	}
	if view == nil {
		var submission models.CourseEvaluationSubmission
		if err := s.db.First(&submission, submissionID).Error; err != nil {
			return nil, courseEvalErr(CodeCourseEvaluationNotFound, "评价记录不存在", err)
		}
		return s.toSubmissionView(&submission)
	}
	return view, nil
}

// Reject 驳回一条 pending 提交，转入 needs_edit。
// 驳回原因 1-500 字符；保留星级与评论，清理临时关联以便重新提交。
func (s *CourseEvaluationService) Reject(adminID, submissionID uint, revision int, reason string) (*SubmissionView, error) {
	if s == nil || s.db == nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "评价服务不可用", nil)
	}
	if adminID == 0 {
		return nil, courseEvalErr(CodeCourseEvaluationForbidden, "无权审核", nil)
	}
	reason = trimCourseEvaluationReason(reason)
	if runeLen(reason) < 1 || runeLen(reason) > 500 {
		return nil, courseEvalErr(CodeCourseEvaluationReasonRequired, "请填写 1-500 字的驳回原因", nil)
	}

	err := s.db.Transaction(func(tx *gorm.DB) error {
		submission, err := lockSubmissionForReview(tx, submissionID)
		if err != nil {
			return err
		}
		if submission.Status != models.CourseEvaluationStatusPending {
			return courseEvalErr(CodeCourseEvaluationNotPending, "该评价不处于待审核状态", nil)
		}
		if submission.Revision != revision {
			return courseEvalErr(CodeCourseEvaluationRevisionConflict, "该评价已被修改，请刷新后重试", nil)
		}

		// 只把当前 revision 置为 needs_edit：保留星级与评论，清理临时关联。
		submission.Status = models.CourseEvaluationStatusNeedsEdit
		submission.ReviewReason = reason
		submission.ReviewedBy = &adminID
		now := time.Now()
		submission.ReviewedAt = &now
		submission.TeacherRatingID = nil
		submission.TeacherID = nil
		if submission.CourseSubjectID != nil {
			var subject models.CourseSubject
			if err := tx.Select("id", "verified").First(&subject, *submission.CourseSubjectID).Error; err == nil && !subject.Verified {
				// 指向未审核学科的临时关联一并清理，避免下次提交误命中。
				submission.CourseSubjectID = nil
				submission.CourseSubjectName = ""
			}
		}
		if err := tx.Save(submission).Error; err != nil {
			return courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "更新评价状态失败", err)
		}

		if err := writeCourseEvaluationAdminLog(tx, adminID, "驳回课程评价",
			submission.CourseName, reason); err != nil {
			return err
		}
		return writeCourseEvaluationNotification(tx, submission, models.CourseEvaluationStatusNeedsEdit)
	})
	if err != nil {
		return nil, err
	}
	var submission models.CourseEvaluationSubmission
	if err := s.db.First(&submission, submissionID).Error; err != nil {
		return nil, courseEvalErr(CodeCourseEvaluationNotFound, "评价记录不存在", err)
	}
	return s.toSubmissionView(&submission)
}

// findOrCreateVerifiedSubject 审核通过时确保学科存在且已审核。
// 命中唯一索引竞争时重新读取 canonical 行，不向调用方暴露 duplicate 错误。
func findOrCreateVerifiedSubject(tx *gorm.DB, submission *models.CourseEvaluationSubmission) (*models.CourseSubject, error) {
	if submission.CourseSubjectID != nil && *submission.CourseSubjectID != 0 {
		var subject models.CourseSubject
		if err := tx.First(&subject, *submission.CourseSubjectID).Error; err != nil {
			return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取学科失败", err)
		}
		if !subject.Verified {
			if err := tx.Model(&models.CourseSubject{}).Where("id = ?", subject.ID).
				Updates(map[string]interface{}{"verified": true}).Error; err != nil {
				return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "审核学科失败", err)
			}
			subject.Verified = true
		}
		return &subject, nil
	}

	name := submission.ProposedCourseName
	if name == "" {
		name = submission.CourseName
	}
	normalized := models.NormalizeCourseSubjectName(name)
	if normalized == "" {
		return nil, courseEvalErr(CodeInvalidCourseEvaluationInput, "课程名为空，无法创建学科", nil)
	}

	var subject models.CourseSubject
	err := tx.Where("normalized_name = ?", normalized).Order("verified DESC, id ASC").First(&subject).Error
	if err == nil {
		if !subject.Verified {
			if err := tx.Model(&models.CourseSubject{}).Where("id = ?", subject.ID).
				Update("verified", true).Error; err != nil {
				return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "审核学科失败", err)
			}
			subject.Verified = true
		}
		return &subject, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取学科失败", err)
	}

	candidate := models.CourseSubject{
		Name:           name,
		NormalizedName: normalized,
		Verified:       true,
	}
	if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&candidate).Error; err != nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "创建学科失败", err)
	}
	if candidate.ID == 0 {
		// 并发下已有同名学科：读取 canonical 行并置为已审核。
		if err := tx.Where("normalized_name = ?", normalized).
			Order("verified DESC, id ASC").First(&subject).Error; err != nil {
			return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取学科失败", err)
		}
		if !subject.Verified {
			if err := tx.Model(&models.CourseSubject{}).Where("id = ?", subject.ID).
				Update("verified", true).Error; err != nil {
				return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "审核学科失败", err)
			}
			subject.Verified = true
		}
		return &subject, nil
	}
	return &candidate, nil
}

// findOrCreateVerifiedTeacher 审核通过时确保教师存在且已审核，并归属该学科。
func findOrCreateVerifiedTeacher(tx *gorm.DB, submission *models.CourseEvaluationSubmission, subject *models.CourseSubject, adminID uint) (*models.Teacher, error) {
	normalized := models.NormalizeTeacherName(submission.TeacherName)
	if submission.TeacherID != nil && *submission.TeacherID != 0 {
		var teacher models.Teacher
		if err := tx.First(&teacher, *submission.TeacherID).Error; err == nil {
			updates := map[string]interface{}{
				"verified":          true,
				"course_subject_id": subject.ID,
			}
			if normalized != "" {
				updates["name_normalized"] = normalized
			}
			if err := tx.Model(&models.Teacher{}).Where("id = ?", teacher.ID).Updates(updates).Error; err != nil {
				return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "审核教师失败", err)
			}
			teacher.Verified = true
			teacher.CourseSubjectID = &subject.ID
			return &teacher, nil
		}
	}
	if normalized == "" {
		return nil, courseEvalErr(CodeInvalidCourseEvaluationInput, "教师名为空，无法创建教师", nil)
	}

	var teacher models.Teacher
	err := tx.Where("course_subject_id = ? AND name_normalized = ?", subject.ID, normalized).
		Order("verified DESC, id ASC").First(&teacher).Error
	if err == nil {
		if !teacher.Verified || teacher.CourseSubjectID == nil || *teacher.CourseSubjectID != subject.ID {
			if err := tx.Model(&models.Teacher{}).Where("id = ?", teacher.ID).Updates(map[string]interface{}{
				"verified":          true,
				"course_subject_id": subject.ID,
			}).Error; err != nil {
				return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "审核教师失败", err)
			}
		}
		teacher.Verified = true
		teacher.CourseSubjectID = &subject.ID
		return &teacher, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取教师失败", err)
	}

	name := submission.ProposedTeacherName
	if name == "" {
		name = submission.TeacherName
	}
	creator := adminID
	candidate := models.Teacher{
		Name:            name,
		Course:          subject.Name,
		Verified:        true,
		CreatedBy:       creator,
		CourseSubjectID: &subject.ID,
		NameNormalized:  normalized,
	}
	if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&candidate).Error; err != nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "创建教师失败", err)
	}
	if candidate.ID == 0 {
		if err := tx.Where("course_subject_id = ? AND name_normalized = ?", subject.ID, normalized).
			Order("verified DESC, id ASC").First(&teacher).Error; err != nil {
			return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取教师失败", err)
		}
		return &teacher, nil
	}
	return &candidate, nil
}

// writeCourseEvaluationAdminLog 记录审核操作，供管理员操作日志展示。
func writeCourseEvaluationAdminLog(tx *gorm.DB, adminID uint, action, target, detail string) error {
	var admin models.User
	_ = tx.Select("nickname").First(&admin, adminID).Error
	if err := tx.Create(&models.AdminLog{
		AdminID:   adminID,
		AdminName: admin.Nickname,
		Action:    action,
		Target:    target,
		Detail:    truncateForLog(detail, 500),
	}).Error; err != nil {
		// 日志失败不应阻断审核本身。
		return nil
	}
	_ = tx.Model(&models.User{}).Where("id = ?", adminID).
		UpdateColumn("admin_exp", gorm.Expr("COALESCE(admin_exp, 0) + 1")).Error
	return nil
}

func truncateForLog(s string, max int) string {
	if runeLen(s) <= max {
		return s
	}
	return string([]rune(s)[:max])
}

func runeLen(s string) int {
	return len([]rune(s))
}

func trimCourseEvaluationReason(reason string) string {
	trimmed := []rune(reason)
	start, end := 0, len(trimmed)
	for start < end && isSpaceRune(trimmed[start]) {
		start++
	}
	for end > start && isSpaceRune(trimmed[end-1]) {
		end--
	}
	return string(trimmed[start:end])
}

func isSpaceRune(r rune) bool {
	return r == ' ' || r == '\t' || r == '\n' || r == '\r' || r == 0x3000
}
