package services

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

func integrationCheckInFixture(t *testing.T, scope string) (*gorm.DB, *IntegrationAuthService, models.IntegrationBinding) {
	t.Helper()
	db := integrationTestDB(t)
	integrationTestUser(t, db, 1)
	require.NoError(t, db.AutoMigrate(&models.CheckIn{}, &models.UserCheckInStat{}, &models.UserExperienceLedger{}, &models.CheckInRepairLog{}, &models.CheckInCompensationCampaign{}, &models.CheckInCompensationEligibility{}, &models.CheckInCompensationClaim{}))
	require.NoError(t, models.EnsureCheckInSchema(db))
	auth := NewIntegrationAuthService(db)
	device, err := auth.RequestDevice(context.Background(), uuid.NewString(), "签到合成安装", scope)
	require.NoError(t, err)
	consent, err := auth.LookupConsent(context.Background(), 1, device.UserCode)
	require.NoError(t, err)
	binding, err := auth.DecideConsent(context.Background(), 1, consent.ID, IntegrationConsentDecision{Allow: true, Scopes: consent.RequestedScopes, Nonce: consent.Nonce})
	require.NoError(t, err)
	return db, auth, binding
}

func TestIntegrationCheckInReusesAppDayAndReward(t *testing.T) {
	db, auth, binding := integrationCheckInFixture(t, IntegrationCheckInScope)
	ctx := context.Background()
	now := time.Date(2026, 10, 30, 16, 30, 0, 0, time.UTC)
	auth.Now = func() time.Time { return now }
	status, err := auth.CheckInForBinding(ctx, binding, false)
	require.NoError(t, err)
	require.Equal(t, false, status.(map[string]interface{})["checked_in"])
	first, err := auth.CheckInForBinding(ctx, binding, true)
	require.NoError(t, err)
	require.Equal(t, "2026-10-31", first.(map[string]interface{})["check_in_date"])
	require.Equal(t, false, first.(map[string]interface{})["already"])
	require.Equal(t, CheckInExpReward(1), first.(map[string]interface{})["exp_earned"])
	location, err := time.LoadLocation("Asia/Shanghai")
	require.NoError(t, err)
	app, err := NewCheckInService(db).CheckIn(1, now.In(location))
	require.NoError(t, err)
	require.True(t, app.Already, "App and plugin must share the same daily fact")
	second, err := auth.CheckInForBinding(ctx, binding, true)
	require.NoError(t, err)
	require.Equal(t, true, second.(map[string]interface{})["already"])
	require.Equal(t, 0, second.(map[string]interface{})["exp_earned"])
	var rows, ledger int64
	require.NoError(t, db.Model(&models.CheckIn{}).Count(&rows).Error)
	require.NoError(t, db.Model(&models.UserExperienceLedger{}).Count(&ledger).Error)
	require.EqualValues(t, 1, rows)
	require.EqualValues(t, 1, ledger)
	now = now.Add(24 * time.Hour)
	third, err := auth.CheckInForBinding(ctx, binding, true)
	require.NoError(t, err)
	require.Equal(t, "2026-11-01", third.(map[string]interface{})["check_in_date"])
	require.Equal(t, 2, third.(map[string]interface{})["streak_days"])
}

func TestIntegrationCheckInRequiresCurrentScopeAndIdentity(t *testing.T) {
	for _, change := range []string{"read_only", "scope_removed", "epoch_changed", "academic_removed", "revoked"} {
		t.Run(change, func(t *testing.T) {
			scope := IntegrationCheckInScope
			if change == "read_only" {
				scope = IntegrationReadScope
			}
			db, auth, binding := integrationCheckInFixture(t, scope)
			switch change {
			case "scope_removed":
				require.NoError(t, db.Model(&models.IntegrationBinding{}).Where("id = ?", binding.ID).Update("scopes", IntegrationReadScope).Error)
			case "epoch_changed":
				require.NoError(t, db.Model(&models.IntegrationBinding{}).Where("id = ?", binding.ID).Update("epoch", binding.Epoch+1).Error)
			case "academic_removed":
				require.NoError(t, db.Where("user_id = ?", 1).Delete(&models.AcademicIdentityBinding{}).Error)
			case "revoked":
				require.NoError(t, auth.Revoke(context.Background(), 1, binding.ID))
			}
			_, err := auth.CheckInForBinding(context.Background(), binding, true)
			require.Error(t, err)
			var rows int64
			require.NoError(t, db.Model(&models.CheckIn{}).Count(&rows).Error)
			require.Zero(t, rows)
		})
	}
}

func TestIntegrationCheckInAuditFailureRollsBackReward(t *testing.T) {
	db, auth, binding := integrationCheckInFixture(t, IntegrationCheckInScope)
	require.NoError(t, db.Callback().Create().Before("gorm:create").Register("synthetic_audit_failure", func(tx *gorm.DB) {
		if tx.Statement.Table == "integration_audits" {
			tx.AddError(errors.New("synthetic audit failure"))
		}
	}))
	t.Cleanup(func() { db.Callback().Create().Remove("synthetic_audit_failure") })
	_, err := auth.CheckInForBinding(context.Background(), binding, true)
	require.Error(t, err)
	var count int64
	require.NoError(t, db.Model(&models.CheckIn{}).Count(&count).Error)
	require.Zero(t, count)
	require.NoError(t, db.Model(&models.UserExperienceLedger{}).Count(&count).Error)
	require.Zero(t, count)
	var user models.User
	require.NoError(t, db.First(&user, 1).Error)
	require.Zero(t, user.Exp)
}

func TestIntegrationCheckInConcurrentRetriesAndRevoke(t *testing.T) {
	db, auth, binding := integrationCheckInFixture(t, IntegrationCheckInScope)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	errors := make(chan error, 12)
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, err := auth.CheckInForBinding(ctx, binding, true); errors <- err }()
	}
	wg.Wait()
	close(errors)
	for err := range errors {
		require.NoError(t, err)
	}
	var count int64
	require.NoError(t, db.Model(&models.CheckIn{}).Count(&count).Error)
	require.EqualValues(t, 1, count)
	require.NoError(t, auth.Revoke(ctx, 1, binding.ID))
	_, err := auth.CheckInForBinding(ctx, binding, true)
	require.Error(t, err)
	var user models.User
	require.NoError(t, db.First(&user, 1).Error)
	require.Equal(t, CheckInExpReward(1), user.Exp)
}
