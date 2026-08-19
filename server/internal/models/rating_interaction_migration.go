package models

import (
	"log"

	"gorm.io/gorm"
)

// EnsureRatingInteractionSchema ensures that the database schema for rating interactions is up to date.
// It removes duplicate ratings keeping the latest one, and creates unique composite indexes.
func EnsureRatingInteractionSchema(db *gorm.DB) error {
	// Cleanup duplicate TeacherRatings
	cleanupTeacherQuery := `
		WITH RankedRatings AS (
			SELECT id,
				   ROW_NUMBER() OVER (PARTITION BY teacher_id, user_id ORDER BY updated_at DESC) as rn
			FROM teacher_ratings
			WHERE deleted_at IS NULL
		)
		UPDATE teacher_ratings
		SET deleted_at = NOW()
		WHERE id IN (
			SELECT id FROM RankedRatings WHERE rn > 1
		) AND deleted_at IS NULL;
	`
	if err := db.Exec(cleanupTeacherQuery).Error; err != nil {
		log.Printf("Error cleaning up duplicate teacher ratings: %v", err)
		return err
	}

	// Create unique index for TeacherRatings
	if err := db.Exec(`
		CREATE UNIQUE INDEX IF NOT EXISTS uq_teacher_rating_user 
		ON teacher_ratings (teacher_id, user_id) 
		WHERE deleted_at IS NULL;
	`).Error; err != nil {
		log.Printf("Error creating unique index for teacher ratings: %v", err)
		return err
	}

	// Cleanup duplicate MajorRatings
	cleanupMajorQuery := `
		WITH RankedRatings AS (
			SELECT id,
				   ROW_NUMBER() OVER (PARTITION BY major_id, user_id ORDER BY updated_at DESC) as rn
			FROM major_ratings
			WHERE deleted_at IS NULL
		)
		UPDATE major_ratings
		SET deleted_at = NOW()
		WHERE id IN (
			SELECT id FROM RankedRatings WHERE rn > 1
		) AND deleted_at IS NULL;
	`
	if err := db.Exec(cleanupMajorQuery).Error; err != nil {
		log.Printf("Error cleaning up duplicate major ratings: %v", err)
		return err
	}

	// Create unique index for MajorRatings
	if err := db.Exec(`
		CREATE UNIQUE INDEX IF NOT EXISTS uq_major_rating_user 
		ON major_ratings (major_id, user_id) 
		WHERE deleted_at IS NULL;
	`).Error; err != nil {
		log.Printf("Error creating unique index for major ratings: %v", err)
		return err
	}

	// Create unique index for Reports (to prevent concurrent identical reports)
	if err := db.Exec(`
		CREATE UNIQUE INDEX IF NOT EXISTS uq_pending_report_target 
		ON reports (reporter_id, target_type, target_id) 
		WHERE status = 'pending';
	`).Error; err != nil {
		log.Printf("Error creating unique index for pending reports: %v", err)
		return err
	}

	// Cleanup duplicate CanteenRatings.
	// CanteenRating 没有 gorm.DeletedAt，历史重复必须硬删除。
	// 保留规则：相同 (canteen_id, user_id) 保留 updated_at 最新，同时刻保留 id 最大。
	//
	// A) 先在同一 (canteen_id,user_id) 组内对同一投票者去重 vote：
	//    每个 (canteen,user,voter) 仅保留 updated_at 最新一次 vote。
	if err := db.Exec(`
		DELETE FROM canteen_rating_votes v
		WHERE EXISTS (
			SELECT 1 FROM canteen_rating_votes v2
			JOIN canteen_ratings r  ON r.id  = v.rating_id
			JOIN canteen_ratings r2 ON r2.id = v2.rating_id
			WHERE r.canteen_id = r2.canteen_id
			  AND r.user_id    = r2.user_id
			  AND v2.user_id   = v.user_id
			  AND (v2.updated_at > v.updated_at
			       OR (v2.updated_at = v.updated_at AND v2.id > v.id))
		);
	`).Error; err != nil {
		log.Printf("Error deduping canteen rating votes: %v", err)
		return err
	}

	// B) 把旧重复 rating 上的 vote 迁移（重挂）到本组保留的 rating 上。
	if err := db.Exec(`
		UPDATE canteen_rating_votes v
		SET rating_id = k.id
		FROM canteen_ratings r
		JOIN (
			SELECT DISTINCT ON (canteen_id, user_id) id, canteen_id, user_id
			FROM canteen_ratings
			ORDER BY canteen_id, user_id, updated_at DESC, id DESC
		) k ON k.canteen_id = r.canteen_id AND k.user_id = r.user_id
		WHERE v.rating_id = r.id AND r.id <> k.id;
	`).Error; err != nil {
		log.Printf("Error remapping canteen rating votes: %v", err)
		return err
	}

	// C) 删除旧重复 rating（保留本组 updated_at 最新、id 最大的那一条）。
	if err := db.Exec(`
		DELETE FROM canteen_ratings
		WHERE id NOT IN (
			SELECT DISTINCT ON (canteen_id, user_id) id
			FROM canteen_ratings
			ORDER BY canteen_id, user_id, updated_at DESC, id DESC
		);
	`).Error; err != nil {
		log.Printf("Error cleaning up duplicate canteen ratings: %v", err)
		return err
	}

	// D) 依据现存投票重算 helpful/unhelpful 计数。
	if err := db.Exec(`
		UPDATE canteen_ratings r SET
			helpful_count = (SELECT COUNT(*) FROM canteen_rating_votes v WHERE v.rating_id = r.id AND v.vote_type = 'up'),
			unhelpful_count = (SELECT COUNT(*) FROM canteen_rating_votes v WHERE v.rating_id = r.id AND v.vote_type = 'down');
	`).Error; err != nil {
		log.Printf("Error recomputing canteen rating counts: %v", err)
		return err
	}

	// Create unique index for CanteenRatings
	if err := db.Exec(`
		CREATE UNIQUE INDEX IF NOT EXISTS uq_canteen_rating_user 
		ON canteen_ratings (canteen_id, user_id);
	`).Error; err != nil {
		log.Printf("Error creating unique index for canteen ratings: %v", err)
		return err
	}

	return nil
}
