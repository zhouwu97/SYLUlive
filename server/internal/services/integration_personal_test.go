package services

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/academic"
	"shenliyuan/internal/models"
)

func personalIntegrationFixture(t *testing.T) (*gorm.DB, *IntegrationAuthService, models.IntegrationBinding, models.IntegrationBinding) {
	t.Helper()
	db := integrationTestDB(t)
	require.NoError(t, db.AutoMigrate(&models.AcademicSnapshot{}, &models.PersonalUploadedSnapshot{}, &models.AIUserPermission{}))
	auth := NewIntegrationAuthService(db)
	bindings := []models.IntegrationBinding{}
	for _, id := range []uint{1, 2} {
		integrationTestUser(t, db, id)
		require.NoError(t, db.Model(&models.User{}).Where("id = ?", id).Updates(map[string]interface{}{"edu_authorized": true, "edu_authorization_generation": 1}).Error)
		for _, document := range models.RequiredLegalDocuments(true) {
			require.NoError(t, db.Where("user_id = ? AND document = ? AND version = ?", id, document, models.LegalDocumentVersion).FirstOrCreate(&models.UserLegalConsent{UserID: id, Document: document, Version: models.LegalDocumentVersion, AcceptedAt: auth.Now()}).Error)
		}
		device, err := auth.RequestDevice(context.Background(), uuid.NewString(), "合成多用户", IntegrationGradesScope+" "+IntegrationErkeScope)
		require.NoError(t, err)
		consent, err := auth.LookupConsent(context.Background(), id, device.UserCode)
		require.NoError(t, err)
		b, err := auth.DecideConsent(context.Background(), id, consent.ID, IntegrationConsentDecision{Allow: true, Scopes: consent.RequestedScopes, Nonce: consent.Nonce})
		require.NoError(t, err)
		bindings = append(bindings, b)
		payload := json.RawMessage(`{"grades":[{"course_name":"用户一课程","fraction":81,"cookie":"must-not-leak","student_id":"private-id"}]}`)
		if id == 2 {
			payload = json.RawMessage(`{"grades":[{"course_name":"用户二课程","fraction":93}]}`)
		}
		err = NewAcademicSnapshotService(db, auth.Now).StoreRemote(context.Background(), AcademicSnapshotInput{UserID: id, Dataset: academic.DatasetGrades, ScopeKey: "2025-2026:3", SchemaVersion: 1, Source: academic.DataSourceRemoteEduFetch, Payload: payload, FetchedAt: auth.Now(), ExpiresAt: auth.Now().Add(time.Hour), CredentialGeneration: 1})
		require.NoError(t, err)
		_, err = NewPersonalSnapshotService(db, auth.Now).StoreErke(context.Background(), id, validErkeSnapshotUpload(auth.Now()))
		require.NoError(t, err)
	}
	return db, auth, bindings[0], bindings[1]
}

func TestIntegrationPersonalOnlyReadsTokenOwnerAndWhitelistedFields(t *testing.T) {
	db, auth, first, second := personalIntegrationFixture(t)
	for _, b := range []models.IntegrationBinding{first, second} {
		result, err := auth.ReadPersonal(context.Background(), b, "grades", 0, 20)
		require.NoError(t, err)
		raw, err := json.Marshal(result)
		require.NoError(t, err)
		if b.OwnerID == 1 {
			require.Contains(t, string(raw), "用户一课程")
			require.NotContains(t, string(raw), "用户二课程")
		} else {
			require.Contains(t, string(raw), "用户二课程")
			require.NotContains(t, string(raw), "用户一课程")
		}
		require.NotContains(t, string(raw), "cookie")
		require.NotContains(t, string(raw), "private-id")
		require.Equal(t, false, result["live_query"])
		_, err = auth.ReadPersonal(context.Background(), b, "erke", 0, 20)
		require.NoError(t, err)
	}
	var count int64
	require.NoError(t, db.Model(&models.IntegrationAudit{}).Where("event IN ?", []string{"grades_read", "erke_read"}).Count(&count).Error)
	require.EqualValues(t, 4, count)
	forged := first
	forged.OwnerID = second.OwnerID
	result, err := auth.ReadPersonal(context.Background(), forged, "grades", 0, 20)
	require.Error(t, err)
	require.Nil(t, result)
}

func TestIntegrationPersonalCurrentPermissionsAndRevocation(t *testing.T) {
	for _, change := range []string{"scope", "epoch", "revoke", "privacy", "generation", "erke_deleted"} {
		t.Run(change, func(t *testing.T) {
			db, auth, b, _ := personalIntegrationFixture(t)
			dataset := "grades"
			switch change {
			case "scope":
				require.NoError(t, db.Model(&b).Update("scopes", IntegrationErkeScope).Error)
			case "epoch":
				require.NoError(t, db.Model(&b).Update("epoch", b.Epoch+1).Error)
				b.Epoch--
			case "revoke":
				require.NoError(t, auth.Revoke(context.Background(), b.OwnerID, b.ID))
			case "privacy":
				require.NoError(t, db.Create(&models.AIUserPermission{UserID: b.OwnerID, Scope: models.AIUserPermissionAcademicCloudStorage, Policy: models.AIUserPermissionNever}).Error)
			case "generation":
				require.NoError(t, db.Model(&models.User{}).Where("id = ?", b.OwnerID).Update("edu_authorization_generation", 2).Error)
			case "erke_deleted":
				dataset = "erke"
				require.NoError(t, NewPersonalSnapshotService(db, auth.Now).DeleteErke(context.Background(), b.OwnerID))
			}
			result, err := auth.ReadPersonal(context.Background(), b, dataset, 0, 20)
			require.Error(t, err)
			require.Nil(t, result)
		})
	}
}

func TestIntegrationPersonalPaginationStaleAndAuditRollback(t *testing.T) {
	db, auth, b, _ := personalIntegrationFixture(t)
	result, err := auth.ReadPersonal(context.Background(), b, "grades", 500, 20)
	require.NoError(t, err)
	require.Empty(t, result["grades"])
	now := auth.Now()
	auth.Now = func() time.Time { return now.Add(48 * time.Hour) }
	result, err = auth.ReadPersonal(context.Background(), b, "grades", 0, 20)
	require.NoError(t, err)
	require.Equal(t, true, result["is_stale"])
	require.NoError(t, db.Callback().Create().Before("gorm:create").Register("reject_personal_audit", func(tx *gorm.DB) {
		if tx.Statement.Table == "integration_audits" {
			tx.AddError(errors.New("synthetic audit failure"))
		}
	}))
	result, err = auth.ReadPersonal(context.Background(), b, "grades", 0, 20)
	require.Error(t, err)
	require.Nil(t, result)
}

func TestIntegrationAdminCannotGrantAndInvalidatesExistingCredentials(t *testing.T) {
	db, auth, b, _ := personalIntegrationFixture(t)
	require.NoError(t, db.Create(&models.User{ID: 8, Role: models.RoleAdmin, AccountStatus: "active"}).Error)
	err := auth.RestrictBinding(context.Background(), 2, b.ID, b.Epoch, []string{IntegrationGradesScope}, false, "合成拒绝管理员越权")
	require.Error(t, err)
	err = auth.RestrictBinding(context.Background(), 8, b.ID, b.Epoch, []string{IntegrationGradesScope, IntegrationCheckInScope}, false, "合成权限添加")
	require.Error(t, err)
	err = auth.RestrictBinding(context.Background(), 8, b.ID, b.Epoch, []string{IntegrationGradesScope}, false, "合成权限缩减")
	require.NoError(t, err)
	_, err = auth.ReadPersonal(context.Background(), b, "grades", 0, 20)
	require.Error(t, err)
	require.NoError(t, db.First(&b, "id = ?", b.ID).Error)
	require.False(t, IntegrationHasScope(b, IntegrationErkeScope))
	err = auth.RestrictBinding(context.Background(), 8, b.ID, b.Epoch, nil, true, "合成撤销操作")
	require.NoError(t, err)
	require.NoError(t, db.First(&b, "id = ?", b.ID).Error)
	require.Equal(t, "revoked", b.State)
	var audits []models.IntegrationAudit
	require.NoError(t, db.Where("actor_id = ?", 8).Find(&audits).Error)
	require.Len(t, audits, 2)
}
