package services

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

func basicIntegrationUser(t *testing.T, db *gorm.DB, id uint) {
	t.Helper()
	require.NoError(t, db.Create(&models.User{ID: id, Nickname: "普通合成账号", AccountStatus: "active"}).Error)
	for _, document := range []string{models.LegalDocumentUserAgreement, models.LegalDocumentPrivacyPolicy} {
		require.NoError(t, db.Create(&models.UserLegalConsent{UserID: id, Document: document, Version: models.LegalDocumentVersion, AcceptedAt: time.Now()}).Error)
	}
}

func TestIntegrationBasicLifecycleDoesNotRequireAcademicIdentity(t *testing.T) {
	for _, method := range []string{"none", models.AcademicVerificationMethodLocalDeclaration, models.AcademicVerificationMethodLegacyMigration} {
		t.Run(method, func(t *testing.T) {
			db := integrationTestDB(t)
			require.NoError(t, db.AutoMigrate(&models.CheckIn{}, &models.UserCheckInStat{}, &models.CheckInMakeupCardGrant{}, &models.UserExperienceLedger{}, &models.AIUserPermission{}, &models.AcademicSnapshot{}, &models.PersonalUploadedSnapshot{}))
			basicIntegrationUser(t, db, 1)
			if method != "none" {
				require.NoError(t, db.Create(&models.AcademicIdentityBinding{UserID: 1, ProviderID: models.AcademicProviderUndergraduate, StudentID: "synthetic-basic", VerifiedAt: time.Now(), VerificationMethod: method, VerificationVersion: "v1"}).Error)
			}
			auth := NewIntegrationAuthService(db)
			now := time.Now()
			auth.Now = func() time.Time { return now }
			ctx := context.Background()
			require.NoError(t, auth.Eligible(ctx, 1), "基础连接只要求有效本站账号")
			device, err := auth.RequestDevice(ctx, uuid.NewString(), "普通用户的 QQ 机器人", "profile:read_minimal checkin:write academic:grades:read academic:erke:read")
			require.NoError(t, err)
			consent, err := auth.LookupConsent(ctx, 1, device.UserCode)
			require.NoError(t, err, "查看连接请求不能被教务核验拦住")
			binding, err := auth.DecideConsent(ctx, 1, consent.ID, IntegrationConsentDecision{Allow: true, Scopes: consent.RequestedScopes, Nonce: consent.Nonce})
			require.NoError(t, err)
			now = now.Add(6 * time.Second)
			tokens, err := auth.ExchangeDevice(ctx, device.DeviceCode)
			require.NoError(t, err)
			current, err := auth.Authenticate(ctx, tokens.AccessToken)
			require.NoError(t, err)
			require.Equal(t, binding.ID, current.ID)
			result, err := auth.CheckInForBinding(ctx, current, true)
			require.NoError(t, err)
			require.Equal(t, false, result.(map[string]interface{})["already"])
			for _, dataset := range []string{"grades", "erke"} {
				_, err = auth.ReadPersonal(ctx, current, dataset, 0, 20)
				require.EqualError(t, err, "academic_sync_required", "仅缺资料的功能返回同步修复提示")
			}
			require.NoError(t, auth.CheckBinding(ctx, current), "教务失败不能使基础连接失效")
			status, err := auth.CheckInForBinding(ctx, current, false)
			require.NoError(t, err)
			require.Equal(t, true, status.(map[string]interface{})["checked_in"])
			refreshed, err := auth.Refresh(ctx, tokens.RefreshToken)
			require.NoError(t, err)
			require.NoError(t, auth.Revoke(ctx, 1, current.ID))
			_, err = auth.Authenticate(ctx, refreshed.AccessToken)
			require.Error(t, err)
		})
	}
}

func TestIntegrationAcademicRepairWorksWithoutRebindingBasicConnection(t *testing.T) {
	db := integrationTestDB(t)
	require.NoError(t, db.AutoMigrate(&models.CheckIn{}, &models.UserCheckInStat{}, &models.UserExperienceLedger{}, &models.AIUserPermission{}, &models.AcademicSnapshot{}, &models.PersonalUploadedSnapshot{}))
	basicIntegrationUser(t, db, 1)
	auth := NewIntegrationAuthService(db)
	ctx := context.Background()
	device, err := auth.RequestDevice(ctx, uuid.NewString(), "先连接后修复资料", "profile:read_minimal checkin:write academic:grades:read")
	require.NoError(t, err)
	consent, err := auth.LookupConsent(ctx, 1, device.UserCode)
	require.NoError(t, err)
	binding, err := auth.DecideConsent(ctx, 1, consent.ID, IntegrationConsentDecision{Allow: true, Scopes: consent.RequestedScopes, Nonce: consent.Nonce})
	require.NoError(t, err)
	_, err = auth.ReadPersonal(ctx, binding, "grades", 0, 20)
	require.EqualError(t, err, "academic_sync_required")
	// 网站本机学校连接只用于关联本人的同步资料，不要求其获得平台学生资格。
	require.NoError(t, db.Create(&models.AcademicIdentityBinding{UserID: 1, ProviderID: models.AcademicProviderUndergraduate, StudentID: "synthetic-repaired", BindingVersion: 1, VerifiedAt: time.Now(), VerificationMethod: models.AcademicVerificationMethodLocalDeclaration, VerificationVersion: "v1"}).Error)
	upload := IntegrationGradesUpload{Consent: true, FetchedAt: auth.Now(), Year: "2026", Semester: 3, Grades: []IntegrationGrade{{CourseName: "本人新同步课程", Score: "88", Credits: 2}}}
	require.NoError(t, auth.StoreUploadedGrades(ctx, 1, upload))
	result, err := auth.ReadPersonal(ctx, binding, "grades", 0, 20)
	require.NoError(t, err)
	require.Equal(t, "本人新同步课程", result["grades"].([]map[string]interface{})[0]["course_name"])
	require.NoError(t, auth.CheckBinding(ctx, binding), "修复学校资料不需要重新绑定 QQ")
}

func TestIntegrationSchoolUnbindClearsPrivateDataButKeepsBasicAccess(t *testing.T) {
	db, auth, first, second := personalIntegrationFixture(t)
	require.NoError(t, db.AutoMigrate(&models.CheckIn{}, &models.UserCheckInStat{}, &models.CheckInMakeupCardGrant{}, &models.UserExperienceLedger{}))
	for _, binding := range []models.IntegrationBinding{first, second} {
		require.NoError(t, db.Model(&models.IntegrationBinding{}).Where("id = ?", binding.ID).Update("scopes", binding.Scopes+" checkin:write").Error)
	}
	require.NoError(t, db.Transaction(func(tx *gorm.DB) error {
		require.NoError(t, tx.Where("user_id = ?", first.OwnerID).Delete(&models.AcademicIdentityBinding{}).Error)
		return InvalidateUserAcademicIntegrationData(tx, first.OwnerID)
	}))
	require.NoError(t, auth.CheckBinding(context.Background(), first))
	_, err := auth.CheckInForBinding(context.Background(), first, true)
	require.NoError(t, err)
	for _, dataset := range []string{"grades", "erke"} {
		_, err = auth.ReadPersonal(context.Background(), first, dataset, 0, 20)
		require.EqualError(t, err, "academic_sync_required")
		_, err = auth.ReadPersonal(context.Background(), second, dataset, 0, 20)
		require.NoError(t, err, "不能影响其他账号的数据或连接")
	}
}
