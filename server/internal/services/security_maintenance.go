package services

import (
	"time"

	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// PurgeSecurityData 清理安全账本的历史聚合，避免长期攻击反向膨胀安全表。
func PurgeSecurityData(db *gorm.DB, now time.Time) error {
	if db == nil {
		return nil
	}
	return db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("last_seen_at < ?", now.Add(-90*24*time.Hour)).Delete(&models.SecurityEvent{}).Error; err != nil {
			return err
		}
		if err := tx.Where("expires_at < ? OR (revoked_at IS NOT NULL AND revoked_at < ?)", now, now.Add(-30*24*time.Hour)).Delete(&models.SecurityBlock{}).Error; err != nil {
			return err
		}
		if err := tx.Where("bucket_start < ?", now.Add(-48*time.Hour)).Delete(&models.VerificationAttemptBucket{}).Error; err != nil {
			return err
		}
		if err := tx.Where("created_at < ?", now.Add(-48*time.Hour)).Delete(&models.VerificationAttempt{}).Error; err != nil {
			return err
		}
		if err := tx.Where("created_at < ?", now.Add(-14*24*time.Hour)).Delete(&models.EmailVerificationRequest{}).Error; err != nil {
			return err
		}
		if err := tx.Where("created_at < ? OR (expires_at < ? AND consumed_at IS NULL)", now.Add(-14*24*time.Hour), now.Add(-24*time.Hour)).Delete(&models.EmailVerificationChallenge{}).Error; err != nil {
			return err
		}
		return tx.Where("last_failure_at < ?", now.Add(-48*time.Hour)).Delete(&models.LoginThrottleRecord{}).Error
	})
}
