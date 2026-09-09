package services

import (
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"testing"
	"time"
)

func TestMarketPublishPolicySurvivesIdentityMigration(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.AcademicIdentityBinding{}, &models.AcademicAccountConfig{}))
	now := time.Now()
	u := models.User{StudentID: "U-1", StudentVerifiedAt: &now, PasswordHash: "test"}
	require.NoError(t, db.Create(&u).Error)
	p := MarketPublishPolicy{DB: db}
	allowed, err := p.CanPublish(u.ID)
	require.NoError(t, err)
	require.False(t, allowed)
	require.NoError(t, MigrateAcademicIdentities(db))
	allowed, err = p.CanPublish(u.ID)
	require.NoError(t, err)
	require.True(t, allowed)
	require.NoError(t, db.Model(&models.User{}).Where("id = ?", u.ID).Update("account_status", "cancelled").Error)
	allowed, err = p.CanPublish(u.ID)
	require.NoError(t, err)
	require.False(t, allowed)
	other := models.User{PasswordHash: "test"}
	require.NoError(t, db.Create(&other).Error)
	require.NoError(t, db.Create(&models.AcademicAccountConfig{UserID: other.ID, ProviderID: models.AcademicProviderGraduate, StudentID: "U-1", State: "active", Revision: 1}).Error)
	allowed, err = p.CanPublish(other.ID)
	require.NoError(t, err)
	require.False(t, allowed)
}

func TestUnboundIdentityCannotReturnThroughLegacyRepair(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.AcademicIdentityBinding{}))
	now := time.Now()
	user := models.User{StudentID: "2026000001", StudentVerifiedAt: &now, PasswordHash: "x"}
	require.NoError(t, db.Create(&user).Error)
	require.NoError(t, MigrateAcademicIdentities(db))
	allowed, err := models.HasVerifiedAcademicIdentity(db, user.ID)
	require.NoError(t, err)
	require.True(t, allowed)
	require.NoError(t, db.Where("user_id = ?", user.ID).Delete(&models.AcademicIdentityBinding{}).Error)
	_, err = models.RepairLegacyAccountIdentityState(db)
	require.NoError(t, err)
	require.NoError(t, MigrateAcademicIdentities(db))
	allowed, err = models.HasVerifiedAcademicIdentity(db, user.ID)
	require.NoError(t, err)
	require.False(t, allowed)
}
