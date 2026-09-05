package models

import (
	"errors"
	"fmt"
	"log"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// EnsureCourseEvaluationSchema 建立课程评价闭环所需的学科、提交和教师归属结构。
//
// 迁移分为四个阶段，全部幂等，可在 SQLite 与 PostgreSQL 上重复执行：
//  1. AutoMigrate 新模型与新增列；
//  2. 归并旧版体育序号学科；
//  3. 回填教师名规范化值；
//  4. 从既有 teachers.course 派生标准学科并回填 course_subject_id
//     （同名学科按"已审核优先、ID 最小优先"收敛）；
//  5. 合并同一学科下的重复教师，重挂评价、投票与提交记录后清理 loser；
//  6. 建立可重复执行的唯一索引。
func EnsureCourseEvaluationSchema(db *gorm.DB) error {
	if db == nil {
		return errors.New("database is nil")
	}
	if err := db.AutoMigrate(&CourseSubject{}, &CourseSubjectAlias{}, &CourseEvaluationSubmission{}, &Teacher{}, &TeacherRating{}); err != nil {
		return fmt.Errorf("课程评价基础表迁移失败: %w", err)
	}
	if err := normalizeLegacyPhysicalEducationSubjects(db); err != nil {
		return err
	}
	if err := backfillTeacherNameNormalized(db); err != nil {
		return err
	}
	if err := backfillCourseSubjects(db); err != nil {
		return err
	}
	if err := mergeDuplicateCourseTeachers(db); err != nil {
		return err
	}
	// 回填过程可能新建同名学科（唯一索引尚未建立），建索引前再收敛一次。
	if err := dedupeCourseSubjects(db); err != nil {
		return err
	}
	if err := dedupeSubmissionRatings(db); err != nil {
		return err
	}
	if err := ensureCourseEvaluationIndexes(db); err != nil {
		return err
	}
	return nil
}

// dedupeSubmissionRatings 在建立提交级唯一约束前收敛历史重复评分，保留最新活动记录。
func dedupeSubmissionRatings(db *gorm.DB) error {
	var groups []struct {
		SubmissionID uint
		Total        int64
	}
	if err := db.Model(&TeacherRating{}).
		Select("course_evaluation_submission_id, COUNT(*) AS total").
		Where("course_evaluation_submission_id IS NOT NULL AND deleted_at IS NULL").
		Group("course_evaluation_submission_id").Having("COUNT(*) > 1").Scan(&groups).Error; err != nil {
		return fmt.Errorf("读取重复提交评分失败: %w", err)
	}
	if len(groups) == 0 {
		return nil
	}
	return db.Transaction(func(tx *gorm.DB) error {
		for _, group := range groups {
			var ratings []TeacherRating
			if err := tx.Where("course_evaluation_submission_id = ? AND deleted_at IS NULL", group.SubmissionID).
				Order("id DESC").Find(&ratings).Error; err != nil {
				return err
			}
			for _, duplicate := range ratings[1:] {
				if err := tx.Delete(&duplicate).Error; err != nil {
					return err
				}
			}
			keeper := ratings[0]
			if err := tx.Model(&CourseEvaluationSubmission{}).Where("id = ?", group.SubmissionID).
				Update("teacher_rating_id", keeper.ID).Error; err != nil {
				return err
			}
		}
		return nil
	})
}

// normalizeLegacyPhysicalEducationSubjects 把旧版本已落库的体育序号学科合并为“体育”。
// 规范化规则升级后，历史 normalized_name 不会自动变化，因此必须在唯一索引检查前完成重挂。
func normalizeLegacyPhysicalEducationSubjects(db *gorm.DB) error {
	legacyNames := []string{"体育1", "体育2", "体育3", "体育4", "体育5"}
	var legacySubjects []CourseSubject
	if err := db.Where("normalized_name IN ?", legacyNames).
		Order("verified DESC, id ASC").Find(&legacySubjects).Error; err != nil {
		return fmt.Errorf("读取旧版体育学科失败: %w", err)
	}
	if len(legacySubjects) == 0 {
		return nil
	}

	return db.Transaction(func(tx *gorm.DB) error {
		for _, legacy := range legacySubjects {
			var canonical CourseSubject
			err := tx.Where("normalized_name = ?", "体育").
				Order("verified DESC, id ASC").First(&canonical).Error
			switch {
			case err == nil:
				if canonical.ID == legacy.ID {
					continue
				}
				if legacy.Verified && !canonical.Verified {
					if err := tx.Model(&CourseSubject{}).Where("id = ?", canonical.ID).
						Update("verified", true).Error; err != nil {
						return err
					}
				}
				if err := tx.Model(&CourseEvaluationSubmission{}).Where("course_subject_id = ?", legacy.ID).
					Update("course_subject_name", canonical.Name).Error; err != nil {
					return err
				}
				if err := rehangCourseSubjectRelations(tx, legacy.ID, canonical.ID); err != nil {
					return err
				}
				if err := tx.Delete(&CourseSubject{}, legacy.ID).Error; err != nil {
					return err
				}
			case errors.Is(err, gorm.ErrRecordNotFound):
				if err := tx.Model(&CourseSubject{}).Where("id = ?", legacy.ID).
					Updates(map[string]interface{}{"name": "体育", "normalized_name": "体育"}).Error; err != nil {
					return err
				}
				if err := tx.Model(&CourseEvaluationSubmission{}).Where("course_subject_id = ?", legacy.ID).
					Update("course_subject_name", "体育").Error; err != nil {
					return err
				}
			default:
				return fmt.Errorf("读取标准体育学科失败: %w", err)
			}
		}
		return nil
	})
}

// backfillTeacherNameNormalized 为空缺的 name_normalized 回填规范化教师名。
func backfillTeacherNameNormalized(db *gorm.DB) error {
	var teachers []Teacher
	if err := db.Where("name_normalized IS NULL OR name_normalized = ''").
		Select("id", "name").Order("id ASC").Find(&teachers).Error; err != nil {
		return fmt.Errorf("读取待回填教师失败: %w", err)
	}
	if len(teachers) == 0 {
		return nil
	}
	return db.Transaction(func(tx *gorm.DB) error {
		for _, teacher := range teachers {
			normalized := NormalizeTeacherName(teacher.Name)
			if normalized == "" {
				continue
			}
			if err := tx.Model(&Teacher{}).Where("id = ?", teacher.ID).
				Update("name_normalized", normalized).Error; err != nil {
				return err
			}
		}
		log.Printf("课程评价迁移: 回填 %d 位教师的规范化姓名", len(teachers))
		return nil
	})
}

// backfillCourseSubjects 从既有 teachers.course 派生标准学科并回填 course_subject_id。
// 历史学科名可能重复，先按"已审核优先、ID 最小优先"选出保留行，再重挂其余教师。
func backfillCourseSubjects(db *gorm.DB) error {
	var teachers []Teacher
	if err := db.Where("course_subject_id IS NULL").
		Select("id", "course", "verified", "created_by").
		Order("verified DESC, id ASC").Find(&teachers).Error; err != nil {
		return fmt.Errorf("读取待归属学科的教师失败: %w", err)
	}
	if len(teachers) == 0 {
		return nil
	}

	// 先把同名学科收敛，避免后续按名称查找学科时命中多行。
	if err := dedupeCourseSubjects(db); err != nil {
		return err
	}

	return db.Transaction(func(tx *gorm.DB) error {
		migrated := 0
		for _, teacher := range teachers {
			subject, err := resolveOrCreateCourseSubject(tx, teacher.Course, teacher.Verified, teacher.CreatedBy)
			if err != nil {
				return err
			}
			if subject == nil {
				// 课程名为空：无法归属学科，跳过并保留为空。
				continue
			}
			if err := tx.Model(&Teacher{}).Where("id = ?", teacher.ID).
				Update("course_subject_id", subject.ID).Error; err != nil {
				return err
			}
			migrated++
		}
		if migrated > 0 {
			log.Printf("课程评价迁移: 为 %d 位教师回填标准学科", migrated)
		}
		return nil
	})
}

// dedupeCourseSubjects 合并同名学科，保留规则为"已审核优先、ID 最小优先"。
func dedupeCourseSubjects(db *gorm.DB) error {
	var rows []struct {
		NormalizedName string
		Total          int64
	}
	if err := db.Model(&CourseSubject{}).
		Select("normalized_name, COUNT(*) AS total").
		Where("normalized_name <> ''").
		Group("normalized_name").Having("COUNT(*) > 1").Scan(&rows).Error; err != nil {
		return fmt.Errorf("读取重复学科分组失败: %w", err)
	}
	if len(rows) == 0 {
		return nil
	}

	return db.Transaction(func(tx *gorm.DB) error {
		for _, row := range rows {
			var subjects []CourseSubject
			if err := tx.Where("normalized_name = ?", row.NormalizedName).
				Order("verified DESC, id ASC").Find(&subjects).Error; err != nil {
				return err
			}
			if len(subjects) < 2 {
				continue
			}
			keeper := subjects[0]
			for _, loser := range subjects[1:] {
				if err := rehangCourseSubjectRelations(tx, loser.ID, keeper.ID); err != nil {
					return err
				}
				if err := tx.Delete(&CourseSubject{}, loser.ID).Error; err != nil {
					return err
				}
			}
			log.Printf("课程评价迁移: 合并学科 %q 的 %d 个重复实体到 #%d",
				row.NormalizedName, len(subjects), keeper.ID)
		}
		return nil
	})
}

// rehangCourseSubjectRelations 把 loser 学科上的教师、提交记录和别名重挂到 keeper。
func rehangCourseSubjectRelations(tx *gorm.DB, loserID, keeperID uint) error {
	if loserID == 0 || keeperID == 0 || loserID == keeperID {
		return nil
	}
	if err := tx.Model(&Teacher{}).Where("course_subject_id = ?", loserID).
		Update("course_subject_id", keeperID).Error; err != nil {
		return err
	}
	if err := tx.Model(&CourseEvaluationSubmission{}).Where("course_subject_id = ?", loserID).
		Update("course_subject_id", keeperID).Error; err != nil {
		return err
	}
	if err := tx.Model(&CourseSubjectAlias{}).Where("course_subject_id = ?", loserID).
		Update("course_subject_id", keeperID).Error; err != nil {
		return err
	}
	return nil
}

// resolveOrCreateCourseSubject 按规范化课程名查找或创建标准学科。
// 课程名为空时返回 nil，不创建学科。
func resolveOrCreateCourseSubject(tx *gorm.DB, courseName string, verified bool, createdBy uint) (*CourseSubject, error) {
	normalized := NormalizeCourseSubjectName(courseName)
	if normalized == "" {
		return nil, nil
	}
	var subject CourseSubject
	err := tx.Where("normalized_name = ?", normalized).Order("verified DESC, id ASC").First(&subject).Error
	if err == nil {
		return &subject, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, err
	}

	name := courseName
	if len([]rune(name)) > CourseSubjectNameMaxLength {
		name = string([]rune(name)[:CourseSubjectNameMaxLength])
	}
	creator := createdBy
	candidate := CourseSubject{
		Name:           name,
		NormalizedName: normalized,
		Verified:       verified,
		CreatedBy:      &creator,
	}
	// 唯一索引竞争时重新读取 canonical 行，不把 duplicate 错误暴露给调用方。
	if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&candidate).Error; err != nil {
		return nil, err
	}
	if candidate.ID == 0 {
		if err := tx.Where("normalized_name = ?", normalized).
			Order("verified DESC, id ASC").First(&subject).Error; err != nil {
			return nil, err
		}
		return &subject, nil
	}
	return &candidate, nil
}

// mergeDuplicateCourseTeachers 合并同一 (course_subject_id, name_normalized) 下的重复教师。
// 保留规则：已审核优先、更新时间最新优先、ID 最小优先。
func mergeDuplicateCourseTeachers(db *gorm.DB) error {
	var groups []struct {
		CourseSubjectID uint
		NameNormalized  string
		Total           int64
	}
	if err := db.Model(&Teacher{}).
		Select("course_subject_id, name_normalized, COUNT(*) AS total").
		Where("course_subject_id IS NOT NULL AND name_normalized <> ''").
		Group("course_subject_id, name_normalized").
		Having("COUNT(*) > 1").Scan(&groups).Error; err != nil {
		return fmt.Errorf("读取重复教师分组失败: %w", err)
	}
	if len(groups) == 0 {
		return nil
	}

	return db.Transaction(func(tx *gorm.DB) error {
		for _, group := range groups {
			var teachers []Teacher
			if err := tx.Where("course_subject_id = ? AND name_normalized = ?", group.CourseSubjectID, group.NameNormalized).
				Order("verified DESC, updated_at DESC, id ASC").Find(&teachers).Error; err != nil {
				return err
			}
			if len(teachers) < 2 {
				continue
			}
			keeper := teachers[0]
			for _, loser := range teachers[1:] {
				if err := mergeTeacherInto(tx, loser, keeper); err != nil {
					return err
				}
			}
			log.Printf("课程评价迁移: 合并教师 %q（学科 #%d）的 %d 个重复实体到 #%d",
				group.NameNormalized, group.CourseSubjectID, len(teachers), keeper.ID)
		}
		return nil
	})
}

// mergeTeacherInto 把 loser 教师的评价、投票和提交记录重挂到 keeper 后删除 loser。
// 删除前逐一确认引用已清空，避免留下孤儿数据。
func mergeTeacherInto(tx *gorm.DB, loser, keeper Teacher) error {
	if loser.ID == keeper.ID {
		return nil
	}

	// 1) 重挂评价：同一用户在 keeper 上已有在架评价时，软删除 loser 的重复评价。
	var ratings []TeacherRating
	if err := tx.Unscoped().Where("teacher_id = ?", loser.ID).Order("id ASC").Find(&ratings).Error; err != nil {
		return err
	}
	for _, rating := range ratings {
		if rating.DeletedAt.Valid {
			// 已软删除的评价直接跟随 keeper，避免成为孤儿。
			if err := tx.Unscoped().Model(&TeacherRating{}).Where("id = ?", rating.ID).
				Update("teacher_id", keeper.ID).Error; err != nil {
				return err
			}
			continue
		}
		var conflicting TeacherRating
		err := tx.Where("teacher_id = ? AND user_id = ?", keeper.ID, rating.UserID).First(&conflicting).Error
		switch {
		case err == nil:
			if err := tx.Delete(&rating).Error; err != nil {
				return err
			}
		case errors.Is(err, gorm.ErrRecordNotFound):
			if err := tx.Model(&TeacherRating{}).Where("id = ?", rating.ID).
				Update("teacher_id", keeper.ID).Error; err != nil {
				return err
			}
		default:
			return err
		}
	}

	// 2) 重挂提交记录指向的教师。
	if err := tx.Model(&CourseEvaluationSubmission{}).Where("teacher_id = ?", loser.ID).
		Update("teacher_id", keeper.ID).Error; err != nil {
		return err
	}

	// 3) 重算 keeper 上的投票计数（评价已重挂，投票随评价一起迁移）。
	if err := recomputeTeacherRatingVoteCounts(tx, keeper.ID); err != nil {
		return err
	}

	// 4) 删除前确认评价与提交记录均已重挂。
	var leftoverRatings int64
	if err := tx.Model(&TeacherRating{}).Where("teacher_id = ?", loser.ID).Count(&leftoverRatings).Error; err != nil {
		return err
	}
	var leftoverSubmissions int64
	if err := tx.Model(&CourseEvaluationSubmission{}).Where("teacher_id = ?", loser.ID).
		Count(&leftoverSubmissions).Error; err != nil {
		return err
	}
	if leftoverRatings > 0 || leftoverSubmissions > 0 {
		return fmt.Errorf("教师 #%d 仍有 %d 条评价、%d 条提交记录未重挂，拒绝删除",
			loser.ID, leftoverRatings, leftoverSubmissions)
	}

	// 5) keeper 继承 loser 的已审核状态，避免审核通过的历史评价被隐藏。
	if loser.Verified && !keeper.Verified {
		if err := tx.Model(&Teacher{}).Where("id = ?", keeper.ID).Update("verified", true).Error; err != nil {
			return err
		}
	}
	return tx.Delete(&Teacher{}, loser.ID).Error
}

// recomputeTeacherRatingVoteCounts 依据现存投票重算指定教师评价的 helpful/unhelpful 计数。
func recomputeTeacherRatingVoteCounts(tx *gorm.DB, teacherID uint) error {
	if teacherID == 0 {
		return nil
	}
	var ratingIDs []uint
	if err := tx.Model(&TeacherRating{}).Where("teacher_id = ?", teacherID).Pluck("id", &ratingIDs).Error; err != nil {
		return err
	}
	now := time.Now()
	for _, ratingID := range ratingIDs {
		var helpful, unhelpful int64
		if err := tx.Model(&TeacherRatingVote{}).
			Where("rating_id = ? AND vote_type = ?", ratingID, "up").Count(&helpful).Error; err != nil {
			return err
		}
		if err := tx.Model(&TeacherRatingVote{}).
			Where("rating_id = ? AND vote_type = ?", ratingID, "down").Count(&unhelpful).Error; err != nil {
			return err
		}
		if err := tx.Model(&TeacherRating{}).Where("id = ?", ratingID).Updates(map[string]interface{}{
			"helpful_count":   helpful,
			"unhelpful_count": unhelpful,
			"updated_at":      now,
		}).Error; err != nil {
			return err
		}
	}
	return nil
}

// ensureCourseEvaluationIndexes 建立课程评价闭环所需的唯一索引。
// 三条语句均使用 IF NOT EXISTS，可在 SQLite 与 PostgreSQL 上重复执行。
func ensureCourseEvaluationIndexes(db *gorm.DB) error {
	statements := []string{
		`CREATE UNIQUE INDEX IF NOT EXISTS uq_course_subjects_normalized_name
		 ON course_subjects(normalized_name)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS uq_teachers_subject_name
		 ON teachers(course_subject_id, name_normalized)
		 WHERE course_subject_id IS NOT NULL`,
		`CREATE UNIQUE INDEX IF NOT EXISTS uq_course_evaluation_submission_dedup
			 ON course_evaluation_submissions(user_id, dedup_key)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS uq_teacher_rating_submission
			 ON teacher_ratings(course_evaluation_submission_id)
			 WHERE course_evaluation_submission_id IS NOT NULL AND deleted_at IS NULL`,
	}
	for _, statement := range statements {
		if err := db.Exec(statement).Error; err != nil {
			return fmt.Errorf("课程评价唯一索引创建失败: %w", err)
		}
	}
	return nil
}
