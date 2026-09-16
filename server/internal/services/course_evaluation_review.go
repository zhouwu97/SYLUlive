package services

import (
	"errors"
	"time"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// ApproveOptions 审核通过的扩展选项。
// KeeperTeacherID 指定"合并到已有教师"的目标；RegisterCourseAlias 控制是否
// 把非标准课程名登记为别名（默认登记，让后续同名提交直接命中标准学科）。
type ApproveOptions struct {
	KeeperTeacherID     uint
	RegisterCourseAlias *bool
}

// Approve 审核通过一条 pending 提交。
//
// 整个审核在一个事务内完成：锁定并校验 pending + revision，
// 创建或复用已审核学科与教师，upsert 教师评价，写审核日志与通知后置 published。
// 唯一索引竞争时重新读取 canonical 行，不向客户端暴露 SQL duplicate 错误。
func (s *CourseEvaluationService) Approve(adminID, submissionID uint, revision int) (*SubmissionView, error) {
	return s.ApproveWithOptions(adminID, submissionID, revision, ApproveOptions{})
}

// ApproveWithOptions 带扩展选项的审核通过。
func (s *CourseEvaluationService) ApproveWithOptions(adminID, submissionID uint, revision int, opts ApproveOptions) (*SubmissionView, error) {
	if s == nil || s.db == nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "评价服务不可用", nil)
	}
	if adminID == 0 {
		return nil, courseEvalErr(CodeCourseEvaluationForbidden, "无权审核", nil)
	}

	// 已审核学科 + 已审核教师直接发布并 upsert 教师评价；否则保持 pending 等待审核。
	// 管理员可在审核时指定合并目标教师：评价与提交全部落到该教师，
	// 用户输入的课程/教师名登记为别名，避免重复实体进入数据库。
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

		var teacher *models.Teacher
		if opts.KeeperTeacherID != 0 {
			teacher, err = resolveVerifiedKeeperTeacher(tx, opts.KeeperTeacherID, subject, submission, adminID)
			if err != nil {
				return err
			}
		} else {
			teacher, err = findOrCreateVerifiedTeacher(tx, submission, subject, adminID)
			if err != nil {
				return err
			}
		}

		// 课程名不是标准名时登记课程别名（幂等）。别名只在确认归属时登记，
		// 让后续同名提交直接命中标准学科，重复实体在进入数据库前被拦住。
		registerAlias := opts.RegisterCourseAlias == nil || *opts.RegisterCourseAlias
		if registerAlias {
			registerCourseSubjectAliasForSubmission(tx, submission, subject)
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
		if err := deleteSubmissionRatings(tx, submission.ID, submission.TeacherRatingID); err != nil {
			return err
		}
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
		Name:            name,
		NormalizedName:  normalized,
		Verified:        true,
		CanonicalSource: models.TeacherSourceEduSchedule,
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
// 解析顺序：提交携带的教师 ID（必须属于该学科、已审核且未被合并）→
// 学科内同名活动教师 → 教师别名（治理合并登记）→ 新建。
// 新建前反向检查教师别名：若别名已指向该学科的其他教师，直接复用目标教师，
// 避免并发场景下"先建别名、再建同名实名教师"重新制造歧义。
func findOrCreateVerifiedTeacher(tx *gorm.DB, submission *models.CourseEvaluationSubmission, subject *models.CourseSubject, adminID uint) (*models.Teacher, error) {
	normalized := models.NormalizeTeacherName(submission.TeacherName)
	if submission.TeacherID != nil && *submission.TeacherID != 0 {
		var teacher models.Teacher
		if err := tx.Where("id = ? AND merged_into_id IS NULL", *submission.TeacherID).First(&teacher).Error; err == nil {
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
	err := tx.Where("course_subject_id = ? AND name_normalized = ? AND merged_into_id IS NULL", subject.ID, normalized).
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

	// 别名命中：治理合并登记过的别名直接解析到目标教师。
	var alias models.TeacherAlias
	err = tx.Where("course_subject_id = ? AND normalized_alias = ?", subject.ID, normalized).First(&alias).Error
	if err == nil {
		var target models.Teacher
		if err := tx.Where("id = ? AND merged_into_id IS NULL", alias.TeacherID).First(&target).Error; err == nil {
			if !target.Verified {
				if err := tx.Model(&models.Teacher{}).Where("id = ?", target.ID).Update("verified", true).Error; err != nil {
					return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "审核教师失败", err)
				}
				target.Verified = true
			}
			target.CourseSubjectID = &subject.ID
			return &target, nil
		}
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
		CanonicalSource: models.TeacherSourceEduSchedule,
	}
	if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&candidate).Error; err != nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "创建教师失败", err)
	}
	if candidate.ID == 0 {
		if err := tx.Where("course_subject_id = ? AND name_normalized = ? AND merged_into_id IS NULL", subject.ID, normalized).
			Order("verified DESC, id ASC").First(&teacher).Error; err != nil {
			return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取教师失败", err)
		}
		return &teacher, nil
	}
	return &candidate, nil
}

// resolveVerifiedKeeperTeacher 审核时把评价并入管理员指定的已有教师。
// 教师必须未合并；课程学科不同的教师不允许作为合并目标（教师实体绑定单一学科）。
func resolveVerifiedKeeperTeacher(tx *gorm.DB, keeperID uint, subject *models.CourseSubject, submission *models.CourseEvaluationSubmission, adminID uint) (*models.Teacher, error) {
	var keeper models.Teacher
	if err := tx.Where("id = ? AND merged_into_id IS NULL", keeperID).First(&keeper).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, courseEvalErr(CodeInvalidCourseEvaluationInput, "合并目标教师不存在或已被合并", nil)
		}
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取合并目标教师失败", err)
	}
	if keeper.CourseSubjectID != nil && *keeper.CourseSubjectID != subject.ID {
		return nil, courseEvalErr(CodeInvalidCourseEvaluationInput, "合并目标教师不属于该课程", nil)
	}
	if !keeper.Verified || keeper.CourseSubjectID == nil {
		if err := tx.Model(&models.Teacher{}).Where("id = ?", keeper.ID).Updates(map[string]interface{}{
			"verified":          true,
			"course_subject_id": subject.ID,
		}).Error; err != nil {
			return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "审核合并目标教师失败", err)
		}
		keeper.Verified = true
		keeper.CourseSubjectID = &subject.ID
	}

	// 用户输入的教师名与目标教师名不同时登记为教师别名（幂等）。
	normalizedInput := models.NormalizeTeacherName(submission.TeacherName)
	if normalizedInput != "" && normalizedInput != models.NormalizeTeacherName(keeper.Name) {
		var existing models.TeacherAlias
		err := tx.Where("course_subject_id = ? AND normalized_alias = ?", subject.ID, normalizedInput).First(&existing).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			creator := adminID
			if err := tx.Create(&models.TeacherAlias{
				TeacherID:       keeper.ID,
				CourseSubjectID: subject.ID,
				Alias:           submission.TeacherName,
				NormalizedAlias: normalizedInput,
				Source:          "merge",
				CreatedBy:       &creator,
			}).Error; err != nil {
				return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "登记教师别名失败", err)
			}
		} else if err != nil {
			return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取教师别名失败", err)
		}
	}
	return &keeper, nil
}

// registerCourseSubjectAliasForSubmission 把提交中的非标准课程名登记为学科别名（幂等）。
// 已有同名学科或别名指向其他学科时静默跳过：审核本身不应被别名冲突阻断，
// 冲突由治理界面的别名管理统一处理。
func registerCourseSubjectAliasForSubmission(tx *gorm.DB, submission *models.CourseEvaluationSubmission, subject *models.CourseSubject) {
	if subject == nil || submission == nil {
		return
	}
	alias := models.CanonicalCourseSubjectName(submission.CourseName)
	normalized := models.NormalizeCourseSubjectName(alias)
	if normalized == "" || normalized == subject.NormalizedName {
		return
	}
	var liveSubject models.CourseSubject
	err := tx.Where("normalized_name = ?", normalized).First(&liveSubject).Error
	if err == nil {
		// 已存在同名词别的真实学科，登记别名只会制造歧义。
		return
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return
	}
	var existing models.CourseSubjectAlias
	err = tx.Where("normalized_alias = ?", normalized).First(&existing).Error
	if err == nil {
		return
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return
	}
	_ = tx.Create(&models.CourseSubjectAlias{
		CourseSubjectID: subject.ID,
		Alias:           alias,
		NormalizedAlias: normalized,
	}).Error
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
