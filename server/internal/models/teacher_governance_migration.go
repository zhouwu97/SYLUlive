package models

import (
	"errors"
	"fmt"
	"log"
	"time"

	"gorm.io/gorm"
)

// EnsureTeacherGovernanceSchema 建立教师/课程数据治理所需的合并标记、别名与审计结构。
//
// 迁移幂等，可在 SQLite 与 PostgreSQL 上重复执行：
//  1. AutoMigrate 别名表、合并记录表与新增列（含 Submission superseded 字段）；
//  2. 回填教师与学科的 canonical_source：历史数据一律 legacy；
//  3. 机械修复旧 exact duplicates：同一学科下完全相同规范化名称的历史重复教师
//     转为 merged_into_id 存档，完整迁移 rating、vote、submission 并落盘审计记录，绝不物理删除；
//  4. 清理旧版全量教师唯一索引 uq_teachers_subject_name；
//  5. 确保活动教师 partial 索引 uq_teachers_active_subject_name 就绪；
//  6. 清洗脏 TeacherAlias 并检查别名歧义。
func EnsureTeacherGovernanceSchema(db *gorm.DB) error {
	if db == nil {
		return errors.New("database is nil")
	}
	if err := db.AutoMigrate(&Teacher{}, &CourseSubject{}, &TeacherAlias{}, &TeacherMergeRecord{}, &CourseEvaluationSubmission{}); err != nil {
		return fmt.Errorf("教师治理基础表迁移失败: %w", err)
	}
	if err := backfillCanonicalSources(db); err != nil {
		return err
	}
	if err := reconcileLegacyExactDuplicateTeachers(db); err != nil {
		return err
	}
	if err := dropLegacyTeacherUniqueIndex(db); err != nil {
		return err
	}
	if err := ensureActiveTeacherUniqueIndex(db); err != nil {
		return err
	}
	if err := cleanDirtyTeacherAliases(db); err != nil {
		return err
	}
	return nil
}

// backfillCanonicalSources 为历史数据回填 legacy 出处。
func backfillCanonicalSources(db *gorm.DB) error {
	result := db.Model(&Teacher{}).
		Where("canonical_source IS NULL OR canonical_source = ''").
		Update("canonical_source", TeacherSourceLegacy)
	if result.Error != nil {
		return fmt.Errorf("回填教师名称出处失败: %w", result.Error)
	}
	result = db.Model(&CourseSubject{}).
		Where("canonical_source IS NULL OR canonical_source = ''").
		Update("canonical_source", TeacherSourceLegacy)
	if result.Error != nil {
		return fmt.Errorf("回填学科名称出处失败: %w", result.Error)
	}
	if result.RowsAffected > 0 {
		log.Printf("教师治理迁移: 历史数据名称出处回填为 legacy")
	}
	return nil
}

// reconcileLegacyExactDuplicateTeachers 机械收敛历史 exact duplicates。
// 同一个 course_subject_id + 完全相同 name_normalized + merged_into_id IS NULL：
// 按 (verified DESC, updated_at DESC, id ASC) 选取 keeper，loser 标记 merged_into_id，
// 完整迁移评价、投票与提交记录，绝不物理删除 loser。
func reconcileLegacyExactDuplicateTeachers(db *gorm.DB) error {
	var groups []struct {
		CourseSubjectID uint
		NameNormalized  string
		Total           int64
	}
	if err := db.Model(&Teacher{}).
		Select("course_subject_id, name_normalized, COUNT(*) AS total").
		Where("course_subject_id IS NOT NULL AND name_normalized <> '' AND merged_into_id IS NULL").
		Group("course_subject_id, name_normalized").
		Having("COUNT(*) > 1").Scan(&groups).Error; err != nil {
		return fmt.Errorf("读取历史技术重复教师分组失败: %w", err)
	}
	if len(groups) == 0 {
		return nil
	}

	return db.Transaction(func(tx *gorm.DB) error {
		for _, group := range groups {
			var teachers []Teacher
			if err := tx.Where("course_subject_id = ? AND name_normalized = ? AND merged_into_id IS NULL",
				group.CourseSubjectID, group.NameNormalized).
				Order("verified DESC, updated_at DESC, id ASC").Find(&teachers).Error; err != nil {
				return err
			}
			if len(teachers) < 2 {
				continue
			}
			keeper := teachers[0]
			batchID := fmt.Sprintf("migration-exact-dedup-%d-%d", group.CourseSubjectID, time.Now().UnixNano())

			for _, loser := range teachers[1:] {
				if err := migrateExactDuplicateTeacher(tx, batchID, keeper, loser); err != nil {
					return fmt.Errorf("收敛历史技术重复教师 #%d 到 #%d 失败: %w", loser.ID, keeper.ID, err)
				}
			}
			log.Printf("教师治理迁移: 机械收敛学科 #%d 下 %d 位重复教师 %q 到 keeper #%d",
				group.CourseSubjectID, len(teachers), group.NameNormalized, keeper.ID)
		}
		return nil
	})
}

// migrateExactDuplicateTeacher 在单个事务内完成数据迁移与 loser 归档，绝不物理删除。
func migrateExactDuplicateTeacher(tx *gorm.DB, batchID string, keeper, loser Teacher) error {
	if keeper.ID == loser.ID {
		return nil
	}
	now := time.Now()
	migratedRatings := 0
	softDeletedRatings := 0
	migratedVotes := 0
	migratedSubmissions := 0
	supersededSubmissions := 0

	// 1. 迁移评价
	var loserRatings []TeacherRating
	if err := tx.Where("teacher_id = ? AND deleted_at IS NULL", loser.ID).Order("id ASC").Find(&loserRatings).Error; err != nil {
		return err
	}

	for _, lRating := range loserRatings {
		var kRating TeacherRating
		err := tx.Where("teacher_id = ? AND user_id = ? AND deleted_at IS NULL", keeper.ID, lRating.UserID).First(&kRating).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			// 无冲突，直接重挂到 keeper
			if err := tx.Model(&TeacherRating{}).Where("id = ?", lRating.ID).Update("teacher_id", keeper.ID).Error; err != nil {
				return err
			}
			migratedRatings++
		} else if err != nil {
			return err
		} else {
			// 同用户评价冲突：按 created_at DESC, id DESC 确定 winner
			var winner, loserR TeacherRating
			winnerIsLoser := false
			if lRating.CreatedAt.After(kRating.CreatedAt) || (lRating.CreatedAt.Equal(kRating.CreatedAt) && lRating.ID > kRating.ID) {
				winner = lRating
				loserR = kRating
				winnerIsLoser = true
			} else {
				winner = kRating
				loserR = lRating
			}

			// 必须先软删除 loser 评价（若 loserR 为 keeper 原有评价，先软删以释放 keeper 的 (teacher_id, user_id) 唯一索引槽位）
			if err := tx.Model(&TeacherRating{}).Where("id = ?", loserR.ID).Updates(map[string]interface{}{
				"deleted_at":        now,
				"moderation_reason": "teacher_merge_duplicate",
			}).Error; err != nil {
				return err
			}
			softDeletedRatings++

			// 胜出评价若来自 loser，在旧 keeper 评价已软删后重挂到 keeper
			if winnerIsLoser {
				if err := tx.Model(&TeacherRating{}).Where("id = ?", lRating.ID).Update("teacher_id", keeper.ID).Error; err != nil {
					return err
				}
				migratedRatings++
			}

			// 投票去重与重挂
			var votes []TeacherRatingVote
			if err := tx.Where("rating_id IN ?", []uint{winner.ID, loserR.ID}).
				Order("updated_at DESC, id DESC").Find(&votes).Error; err != nil {
				return err
			}
			seenVoters := map[uint]bool{}
			for _, v := range votes {
				if seenVoters[v.UserID] {
					if err := tx.Delete(&TeacherRatingVote{}, v.ID).Error; err != nil {
						return err
					}
				} else {
					seenVoters[v.UserID] = true
					if v.RatingID != winner.ID {
						if err := tx.Model(&TeacherRatingVote{}).Where("id = ?", v.ID).
							Update("rating_id", winner.ID).Error; err != nil {
							return err
						}
						migratedVotes++
					}
				}
			}

			// 重算 winner 评价的有用/无用统计
			var upCount, downCount int64
			if err := tx.Model(&TeacherRatingVote{}).Where("rating_id = ? AND vote_type = ?", winner.ID, "up").Count(&upCount).Error; err != nil {
				return err
			}
			if err := tx.Model(&TeacherRatingVote{}).Where("rating_id = ? AND vote_type = ?", winner.ID, "down").Count(&downCount).Error; err != nil {
				return err
			}
			if err := tx.Model(&TeacherRating{}).Where("id = ?", winner.ID).Updates(map[string]interface{}{
				"helpful_count":   int(upCount),
				"unhelpful_count": int(downCount),
			}).Error; err != nil {
				return err
			}

			// 关联提交标记为 superseded
			var loserSubs []CourseEvaluationSubmission
			if err := tx.Where("teacher_rating_id = ?", loserR.ID).Find(&loserSubs).Error; err == nil {
				var winnerSub CourseEvaluationSubmission
				var winnerSubID *uint
				if err := tx.Where("teacher_rating_id = ?", winner.ID).First(&winnerSub).Error; err == nil {
					winnerSubID = &winnerSub.ID
				}
				for _, sub := range loserSubs {
					if err := tx.Model(&CourseEvaluationSubmission{}).Where("id = ?", sub.ID).Updates(map[string]interface{}{
						"status":                      CourseEvaluationStatusSuperseded,
						"teacher_id":                  keeper.ID,
						"teacher_rating_id":           nil,
						"superseded_by_submission_id": winnerSubID,
						"superseded_reason":           "teacher_merge_duplicate",
					}).Error; err != nil {
						return err
					}
					supersededSubmissions++
				}
			}
		}
	}

	// 2. 迁移剩余普通提交
	res := tx.Model(&CourseEvaluationSubmission{}).
		Where("teacher_id = ? AND status <> ?", loser.ID, CourseEvaluationStatusSuperseded).
		Updates(map[string]interface{}{
			"teacher_id":   keeper.ID,
			"teacher_name": keeper.Name,
		})
	if res.Error != nil {
		return res.Error
	}
	migratedSubmissions += int(res.RowsAffected)

	// 3. 别名重挂
	_ = tx.Model(&TeacherAlias{}).Where("teacher_id = ?", loser.ID).Update("teacher_id", keeper.ID).Error

	// 4. 压平既有合并链条（避免 X -> loser -> keeper）
	_ = tx.Model(&Teacher{}).Where("merged_into_id = ?", loser.ID).Update("merged_into_id", keeper.ID).Error

	// 5. 标记 loser 为 merged
	if err := tx.Model(&Teacher{}).Where("id = ?", loser.ID).Update("merged_into_id", keeper.ID).Error; err != nil {
		return err
	}

	// 6. keeper 继承 verified
	if loser.Verified && !keeper.Verified {
		if err := tx.Model(&Teacher{}).Where("id = ?", keeper.ID).Update("verified", true).Error; err != nil {
			return err
		}
		keeper.Verified = true
	}

	// 7. 重算 keeper 上全部在架评价的投票计数
	if err := recomputeTeacherRatingVoteCounts(tx, keeper.ID); err != nil {
		return err
	}

	// 8. 写入治理审计快照
	record := TeacherMergeRecord{
		BatchID:                   batchID,
		KeeperID:                  keeper.ID,
		LoserID:                   loser.ID,
		KeeperNameSnapshot:        keeper.Name,
		LoserNameSnapshot:         loser.Name,
		KeeperSubjectNameSnapshot: keeper.Course,
		LoserSubjectNameSnapshot:  loser.Course,
		MigratedRatings:           migratedRatings,
		SoftDeletedRatings:        softDeletedRatings,
		MigratedVotes:             migratedVotes,
		MigratedSubmissions:       migratedSubmissions,
		SupersededSubmissions:     supersededSubmissions,
		CourseAliasesAdded:        0,
		TeacherAliasesAdded:       0,
		AdminID:                   0,
		AdminName:                 "system_migration",
		CreatedAt:                 now,
	}
	return tx.Create(&record).Error
}

// dropLegacyTeacherUniqueIndex 移除旧版"包含全部教师"的唯一索引。
func dropLegacyTeacherUniqueIndex(db *gorm.DB) error {
	if err := db.Exec(`DROP INDEX IF EXISTS uq_teachers_subject_name`).Error; err != nil {
		return fmt.Errorf("移除旧版教师唯一索引失败: %w", err)
	}
	return nil
}

// ensureActiveTeacherUniqueIndex 确保活动教师 partial index 存在。
func ensureActiveTeacherUniqueIndex(db *gorm.DB) error {
	stmt := `CREATE UNIQUE INDEX IF NOT EXISTS uq_teachers_active_subject_name
		ON teachers(course_subject_id, name_normalized)
		WHERE course_subject_id IS NOT NULL AND merged_into_id IS NULL`
	if err := db.Exec(stmt).Error; err != nil {
		return fmt.Errorf("创建活动教师唯一索引失败: %w", err)
	}
	return nil
}

// cleanDirtyTeacherAliases 清理无法成立的别名，并对同名冲突记录告警。
func cleanDirtyTeacherAliases(db *gorm.DB) error {
	// 1. 清理空别名
	_ = db.Where("normalized_alias = '' OR normalized_alias IS NULL").Delete(&TeacherAlias{}).Error

	// 2. 将指向已合并教师的别名重挂至其 keeper
	var mergedAliases []struct {
		AliasID      uint `gorm:"column:alias_id"`
		MergedIntoID uint `gorm:"column:merged_into_id"`
	}
	if err := db.Table("teacher_aliases ta").
		Select("ta.id AS alias_id, t.merged_into_id AS merged_into_id").
		Joins("JOIN teachers t ON t.id = ta.teacher_id").
		Where("t.merged_into_id IS NOT NULL").Scan(&mergedAliases).Error; err == nil {
		for _, row := range mergedAliases {
			if row.MergedIntoID != 0 {
				_ = db.Model(&TeacherAlias{}).Where("id = ?", row.AliasID).Update("teacher_id", row.MergedIntoID).Error
			}
		}
	}

	// 3. 检查与活动教师真实 canonical 名的冲突（不静默删除，打出 warning 留待后台展示）
	var conflicts []TeacherAlias
	if err := db.Table("teacher_aliases ta").
		Select("ta.*").
		Joins("JOIN teachers t ON t.course_subject_id = ta.course_subject_id AND t.name_normalized = ta.normalized_alias AND t.merged_into_id IS NULL AND t.id <> ta.teacher_id").
		Find(&conflicts).Error; err == nil && len(conflicts) > 0 {
		for _, conflict := range conflicts {
			log.Printf("教师治理迁移 WARNING: 教师别名 ID #%d (别名 %q) 与学科 #%d 下其他活动教师存在名称冲突，需在治理界面复核",
				conflict.ID, conflict.Alias, conflict.CourseSubjectID)
		}
	}
	return nil
}
