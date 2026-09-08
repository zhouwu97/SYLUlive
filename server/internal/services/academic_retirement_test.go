package services

import (
	"context"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"testing"
)

func TestAcademicRetirementPreservesIdentityAndQueuesCleanup(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.EduCredentialCleanupJob{}, &models.AcademicIdentityBinding{}))
	user := models.User{PasswordHash: "app-password-hash", EduStudentID: "OLD", EduAuthorized: true, EduPassword: "fixture", EduCookie: "fixture", EduAuthorizationGeneration: 3}
	require.NoError(t, db.Create(&user).Error)
	ctx := context.Background()
	require.Error(t, PrepareAcademicRetirement(ctx, db, false, true, 100))
	before, err := InventoryAcademicRetirement(ctx, db)
	require.NoError(t, err)
	require.Equal(t, int64(1), before.SecretRows)
	require.NoError(t, PrepareAcademicRetirement(ctx, db, true, true, 100))
	require.NoError(t, PrepareAcademicRetirement(ctx, db, true, true, 100))
	after, err := InventoryAcademicRetirement(ctx, db)
	require.NoError(t, err)
	require.Zero(t, after.SecretRows)
	require.Equal(t, int64(1), after.PendingCleanup)
	require.NoError(t, db.First(&user, user.ID).Error)
	require.Equal(t, "app-password-hash", user.PasswordHash)
	require.Equal(t, uint(3), user.EduAuthorizationGeneration)
	require.False(t, user.EduAuthorized)
}
