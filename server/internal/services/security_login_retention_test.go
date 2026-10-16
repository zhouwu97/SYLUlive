package services

import (
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

func TestSecurityPurgeBoundsLoginHistoryWithoutDeletingOtherAudits(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.AccountSecurityAuditLog{}, &models.SecurityEvent{}, &models.SecurityBlock{},
		&models.VerificationAttemptBucket{}, &models.VerificationAttempt{}, &models.EmailVerificationRequest{},
		&models.EmailVerificationChallenge{}, &models.LoginThrottleRecord{}))
	now := time.Now()
	rows := []models.AccountSecurityAuditLog{
		{UserID: 1, Action: "login_success", CreatedAt: now.Add(-91 * 24 * time.Hour)},
		{UserID: 1, Action: "login_success", CreatedAt: now.Add(-89 * 24 * time.Hour)},
		{UserID: 1, Action: "password_reset_email", CreatedAt: now.Add(-91 * 24 * time.Hour)},
	}
	require.NoError(t, db.Create(&rows).Error)
	require.NoError(t, PurgeSecurityData(db, now))
	var kept []models.AccountSecurityAuditLog
	require.NoError(t, db.Order("id ASC").Find(&kept).Error)
	require.Len(t, kept, 2)
	require.Equal(t, rows[1].ID, kept[0].ID)
	require.Equal(t, rows[2].ID, kept[1].ID)
}
