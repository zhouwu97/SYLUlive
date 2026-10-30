package services

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/postgres"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"shenliyuan/internal/models"
)

func integrationTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	if dsn := os.Getenv("INTEGRATION_TEST_POSTGRES_DSN"); dsn != "" {
		// 只允许显式本机可丢弃库；每个测试独立 schema，绝不迁移已有业务表。
		require.Contains(t, dsn, "host=127.0.0.1 ")
		require.Contains(t, dsn, "dbname=sylulive_integration_test ")
		root, err := gorm.Open(postgres.Open(dsn), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
		require.NoError(t, err)
		schema := "integration_" + strings.ReplaceAll(uuid.NewString(), "-", "")
		require.NoError(t, root.Exec("CREATE SCHEMA "+schema).Error)
		db, err := gorm.Open(postgres.Open(dsn+" search_path="+schema), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
		require.NoError(t, err)
		sqlDB, _ := db.DB()
		sqlDB.SetMaxOpenConns(8)
		t.Cleanup(func() {
			_ = sqlDB.Close()
			_ = root.Exec("DROP SCHEMA " + schema + " CASCADE").Error
			pool, _ := root.DB()
			_ = pool.Close()
		})
		integrationMigrate(t, db)
		return db
	}
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = sqlDB.Close() })
	integrationMigrate(t, db)
	return db
}
func integrationMigrate(t *testing.T, db *gorm.DB) {
	t.Helper()
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}, &models.AcademicIdentityBinding{}, &models.IntegrationBinding{}, &models.IntegrationCredential{}, &models.IntegrationDeviceRequest{}, &models.IntegrationAction{}, &models.IntegrationAudit{}, &models.IntegrationRateBucket{}))
}
func integrationTestUser(t *testing.T, db *gorm.DB, id uint) {
	t.Helper()
	require.NoError(t, db.Create(&models.User{ID: id, Nickname: fmt.Sprintf("合成用户%d", id), PasswordHash: "synthetic", AccountStatus: "active"}).Error)
	require.NoError(t, db.Create(&models.AcademicIdentityBinding{UserID: id, ProviderID: models.AcademicProviderUndergraduate, StudentID: fmt.Sprintf("synthetic-%d", id), BindingVersion: 1, VerifiedAt: time.Now(), VerificationMethod: models.AcademicVerificationMethodSchoolProfile, VerificationVersion: "v1"}).Error)
	for _, document := range []string{models.LegalDocumentUserAgreement, models.LegalDocumentPrivacyPolicy} {
		require.NoError(t, db.Create(&models.UserLegalConsent{UserID: id, Document: document, Version: models.LegalDocumentVersion, AcceptedAt: time.Now()}).Error)
	}
}
func integrationAuthorize(t *testing.T, s *IntegrationAuthService, owner uint, install string) (models.IntegrationBinding, IntegrationDeviceResponse) {
	t.Helper()
	ctx := context.Background()
	device, err := s.RequestDevice(ctx, install, "我的测试助手", "profile:read_minimal community:read content:read_own_public actions:read_own community:propose")
	require.NoError(t, err)
	consent, err := s.LookupConsent(ctx, owner, device.UserCode)
	require.NoError(t, err)
	b, err := s.DecideConsent(ctx, owner, consent.ID, IntegrationConsentDecision{Allow: true, Scopes: consent.RequestedScopes, Nonce: consent.Nonce})
	require.NoError(t, err)
	return b, device
}
func TestIntegrationDeviceAuthorizationAndCredentialSeparation(t *testing.T) {
	db := integrationTestDB(t)
	integrationTestUser(t, db, 1)
	s := NewIntegrationAuthService(db)
	now := time.Now()
	s.Now = func() time.Time { return now }
	b, device := integrationAuthorize(t, s, 1, uuid.NewString())
	require.EqualValues(t, 1, b.OwnerID)
	_, err := s.ExchangeDevice(context.Background(), device.DeviceCode)
	require.EqualError(t, err, "slow_down")
	now = now.Add(11 * time.Second)
	tokens, err := s.ExchangeDevice(context.Background(), device.DeviceCode)
	require.NoError(t, err)
	actual, err := s.Authenticate(context.Background(), tokens.AccessToken)
	require.NoError(t, err)
	require.Equal(t, b.ID, actual.ID)
	for _, wrong := range []string{tokens.RefreshToken, device.DeviceCode, "g_old-run-grant", "eyJ.app-jwt"} {
		_, err = s.Authenticate(context.Background(), wrong)
		require.EqualError(t, err, "invalid_token")
	}
	_, err = s.ExchangeDevice(context.Background(), device.DeviceCode)
	require.EqualError(t, err, "invalid_grant")
	var rows []models.IntegrationCredential
	require.NoError(t, db.Find(&rows).Error)
	raw, err := json.Marshal(rows)
	require.NoError(t, err)
	require.NotContains(t, string(raw), tokens.AccessToken)
	require.NotContains(t, string(raw), tokens.RefreshToken)
	require.Len(t, rows, 2)
	require.NotEqual(t, tokens.AccessToken, rows[0].TokenHash)
}
func TestIntegrationQualificationDoesNotUseSelfDeclaredOrHistoricalIdentity(t *testing.T) {
	for _, method := range []string{"", models.AcademicVerificationMethodLocalDeclaration, models.AcademicVerificationMethodLegacyMigration, "school_profile_v2"} {
		t.Run(method, func(t *testing.T) {
			db := integrationTestDB(t)
			integrationTestUser(t, db, 1)
			require.NoError(t, db.Model(&models.AcademicIdentityBinding{}).Where("user_id = 1").Update("verification_method", method).Error)
			s := NewIntegrationAuthService(db)
			require.EqualError(t, s.Eligible(context.Background(), 1), "academic_verification_required")
		})
	}
}
func TestIntegrationConsentRejectsOtherOwnerAndScopeEscalation(t *testing.T) {
	db := integrationTestDB(t)
	integrationTestUser(t, db, 1)
	integrationTestUser(t, db, 2)
	s := NewIntegrationAuthService(db)
	ctx := context.Background()
	device, err := s.RequestDevice(ctx, uuid.NewString(), "设备", "community:read")
	require.NoError(t, err)
	consent, err := s.LookupConsent(ctx, 1, device.UserCode)
	require.NoError(t, err)
	_, err = s.LookupConsent(ctx, 2, device.UserCode)
	require.EqualError(t, err, "device_request_conflict")
	_, err = s.DecideConsent(ctx, 2, consent.ID, IntegrationConsentDecision{Allow: true, Nonce: consent.Nonce, Scopes: []string{"community:read"}})
	require.EqualError(t, err, "consent_unavailable")
	_, err = s.DecideConsent(ctx, 1, consent.ID, IntegrationConsentDecision{Allow: true, Nonce: "wrong", Scopes: []string{"community:read"}})
	require.EqualError(t, err, "confirmation_required")
	_, err = s.DecideConsent(ctx, 1, consent.ID, IntegrationConsentDecision{Allow: true, Nonce: consent.Nonce, Scopes: []string{"community:read", "community:propose", "actions:read_own"}})
	require.EqualError(t, err, "invalid_scope")
	_, err = s.DecideConsent(ctx, 1, consent.ID, IntegrationConsentDecision{Allow: false, Nonce: consent.Nonce})
	require.NoError(t, err)
	_, err = s.ExchangeDevice(ctx, device.DeviceCode)
	require.EqualError(t, err, "access_denied")
}
func TestIntegrationReplacementRevocationAndRefreshReuse(t *testing.T) {
	db := integrationTestDB(t)
	integrationTestUser(t, db, 1)
	s := NewIntegrationAuthService(db)
	now := time.Now()
	s.Now = func() time.Time { return now }
	ctx := context.Background()
	first, device := integrationAuthorize(t, s, 1, uuid.NewString())
	now = now.Add(6 * time.Second)
	tokens, err := s.ExchangeDevice(ctx, device.DeviceCode)
	require.NoError(t, err)
	rotated, err := s.Refresh(ctx, tokens.RefreshToken)
	require.NoError(t, err)
	_, err = s.Refresh(ctx, tokens.RefreshToken)
	require.EqualError(t, err, "invalid_grant")
	_, err = s.Authenticate(ctx, rotated.AccessToken)
	require.EqualError(t, err, "invalid_token")
	second, device2 := integrationAuthorize(t, s, 1, uuid.NewString())
	now = now.Add(6 * time.Second)
	tokens2, err := s.ExchangeDevice(ctx, device2.DeviceCode)
	require.NoError(t, err)
	require.NotEqual(t, first.ID, second.ID)
	d3, err := s.RequestDevice(ctx, uuid.NewString(), "新助手", "community:read")
	require.NoError(t, err)
	c3, err := s.LookupConsent(ctx, 1, d3.UserCode)
	require.NoError(t, err)
	_, err = s.DecideConsent(ctx, 1, c3.ID, IntegrationConsentDecision{Allow: true, Scopes: []string{"community:read"}, Nonce: c3.Nonce})
	require.EqualError(t, err, "binding_conflict")
	_, err = s.DecideConsent(ctx, 1, c3.ID, IntegrationConsentDecision{Allow: true, Scopes: []string{"community:read"}, Nonce: c3.Nonce, ReplaceBindingID: second.ID, ExpectedEpoch: second.Epoch})
	require.NoError(t, err)
	_, err = s.Authenticate(ctx, tokens2.AccessToken)
	require.EqualError(t, err, "invalid_token")
}
func TestIntegrationLiveEligibilityAndCredentialExpiry(t *testing.T) {
	for _, mutation := range []string{"academic_version", "academic_delete", "password_version", "legal_revoke", "disabled", "expiry"} {
		t.Run(mutation, func(t *testing.T) {
			db := integrationTestDB(t)
			integrationTestUser(t, db, 1)
			s := NewIntegrationAuthService(db)
			now := time.Now()
			s.Now = func() time.Time { return now }
			_, device := integrationAuthorize(t, s, 1, uuid.NewString())
			now = now.Add(6 * time.Second)
			tokens, err := s.ExchangeDevice(context.Background(), device.DeviceCode)
			require.NoError(t, err)
			switch mutation {
			case "academic_version":
				require.NoError(t, db.Model(&models.AcademicIdentityBinding{}).Where("user_id = 1").Update("binding_version", 2).Error)
			case "academic_delete":
				require.NoError(t, db.Where("user_id = 1").Delete(&models.AcademicIdentityBinding{}).Error)
			case "password_version":
				require.NoError(t, db.Model(&models.User{}).Where("id = 1").Update("token_version", 2).Error)
			case "legal_revoke":
				require.NoError(t, db.Model(&models.User{}).Where("id = 1").Update("legal_consent_revoked_at", now).Error)
			case "disabled":
				require.NoError(t, db.Model(&models.User{}).Where("id = 1").Update("account_status", "cancelled").Error)
			case "expiry":
				now = now.Add(31 * 24 * time.Hour)
			}
			_, err = s.Authenticate(context.Background(), tokens.AccessToken)
			require.Error(t, err)
			_, err = s.Refresh(context.Background(), tokens.RefreshToken)
			require.Error(t, err)
		})
	}
}
func TestIntegrationConcurrentBindingAllowsOneActiveAuthorization(t *testing.T) {
	db := integrationTestDB(t)
	integrationTestUser(t, db, 1)
	s := NewIntegrationAuthService(db)
	ctx := context.Background()
	var consents []IntegrationConsent
	for i := 0; i < 2; i++ {
		d, err := s.RequestDevice(ctx, uuid.NewString(), "并发设备", "community:read")
		require.NoError(t, err)
		c, err := s.LookupConsent(ctx, 1, d.UserCode)
		require.NoError(t, err)
		consents = append(consents, c)
	}
	var wg sync.WaitGroup
	out := make(chan error, 2)
	for _, c := range consents {
		wg.Add(1)
		go func(c IntegrationConsent) {
			defer wg.Done()
			_, err := s.DecideConsent(ctx, 1, c.ID, IntegrationConsentDecision{Allow: true, Scopes: []string{"community:read"}, Nonce: c.Nonce})
			out <- err
		}(c)
	}
	wg.Wait()
	close(out)
	success := 0
	for err := range out {
		if err == nil {
			success++
		} else {
			require.EqualError(t, err, "binding_conflict")
		}
	}
	require.Equal(t, 1, success)
	var count int64
	require.NoError(t, db.Model(&models.IntegrationBinding{}).Where("state = ?", "active").Count(&count).Error)
	require.EqualValues(t, 1, count)
}
