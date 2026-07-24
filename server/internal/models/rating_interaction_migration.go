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

	return nil
}
