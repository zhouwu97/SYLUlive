package handlers

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func TestAcademicIdentityProjectionSurvivesChangeAndPartialUnbind(t *testing.T) {
	h, db, _, user := newAcademicIdentityTestHandler(t)
	require.NoError(t, db.AutoMigrate(&models.UserLegalConsent{}, &models.AccountSecurityAuditLog{}, &models.EduCredentialCleanupJob{}))
	now := time.Now()
	require.NoError(t, h.persistBinding(user.ID, models.AcademicProviderUndergraduate, "U-A", now, "school_profile", "v1"))
	require.NoError(t, h.persistBinding(user.ID, models.AcademicProviderGraduate, "G-B", now, "school_profile", "v1"))
	// 即使旧投影完全错误，两个本人接口依赖的响应仍以 binding 为准。
	user.StudentID = "STALE"
	profile, err := selfUserResponseForDB(db, user)
	require.NoError(t, err)
	require.True(t, profile.StudentVerified)
	require.Equal(t, "U-A", profile.StudentID)
	require.Len(t, profile.AcademicIdentities, 2)
	require.False(t, profile.CanResetViaEdu)
	var old models.AcademicIdentityBinding
	require.NoError(t, db.Where("user_id = ? AND provider_id = ?", user.ID, models.AcademicProviderUndergraduate).First(&old).Error)
	require.NoError(t, h.changeBinding(academicChallengeClaims{UserID: user.ID, CurrentBindingID: old.ID,
		CurrentBindingVersion: old.BindingVersion, CurrentProviderID: old.ProviderID, CurrentStudentID: old.StudentID,
		ProviderID: old.ProviderID, StudentID: "U-C"}, now))
	profile, err = selfUserResponseForDB(db, user)
	require.NoError(t, err)
	require.Equal(t, "U-C", profile.StudentID)
	auth := &AuthHandler{db: db}
	_, err = auth.findLoginUser("U-A")
	require.Error(t, err)
	loggedIn, err := auth.findLoginUser(normalizeLoginAccount(" U-C "))
	require.NoError(t, err)
	require.Equal(t, user.ID, loggedIn.ID)
	router := academicIdentityRouter(h, user.ID)
	req := httptest.NewRequest(http.MethodDelete, "/identities", bytes.NewBufferString(`{"provider_id":"sylu_undergraduate","student_id":"U-C"}`))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)
	require.Equal(t, http.StatusOK, w.Code, w.Body.String())
	profile, err = selfUserResponseForDB(db, user)
	require.NoError(t, err)
	require.True(t, profile.StudentVerified)
	require.Equal(t, "G-B", profile.StudentID)
	loggedIn, err = auth.findLoginUser("G-B")
	require.NoError(t, err)
	require.Equal(t, user.ID, loggedIn.ID)
}

func TestAcademicIdentityMigrationDoesNotOverrideExistingProvider(t *testing.T) {
	h, db, _, user := newAcademicIdentityTestHandler(t)
	now := time.Now()
	require.NoError(t, db.Model(&user).Updates(map[string]interface{}{"student_id": "OLD", "student_verified_at": now}).Error)
	require.NoError(t, services.MigrateAcademicIdentities(db))
	require.NoError(t, services.MigrateAcademicIdentities(db))
	bindings, err := services.VerifiedAcademicIdentities(db, user.ID)
	require.NoError(t, err)
	require.Len(t, bindings, 1)
	require.Equal(t, "OLD", bindings[0].StudentID)
	loginAvailable, err := hasStudentLoginIdentity(db, user)
	require.NoError(t, err)
	require.True(t, loginAvailable)
	require.NoError(t, h.persistBinding(user.ID, models.AcademicProviderGraduate, "G-NEW", now, "school_profile", "v1"))
	require.NoError(t, db.Model(&user).Update("student_id", "STALE").Error)
	require.NoError(t, services.MigrateAcademicIdentities(db))
	bindings, err = services.VerifiedAcademicIdentities(db, user.ID)
	require.NoError(t, err)
	require.Len(t, bindings, 2)
	require.Equal(t, "OLD", bindings[0].StudentID)
	require.NoError(t, db.Where("user_id = ? AND provider_id = ?", user.ID, models.AcademicProviderUndergraduate).Delete(&models.AcademicIdentityBinding{}).Error)
	require.NoError(t, services.MigrateAcademicIdentities(db))
	bindings, err = services.VerifiedAcademicIdentities(db, user.ID)
	require.NoError(t, err)
	require.Len(t, bindings, 1)
	require.Equal(t, models.AcademicProviderGraduate, bindings[0].ProviderID)
}

func TestAcademicIdentityAmbiguousStudentCannotReplaceEmailLogin(t *testing.T) {
	h, db, _, user := newAcademicIdentityTestHandler(t)
	other := models.User{PasswordHash: "hash", AccountStatus: "active"}
	require.NoError(t, db.Create(&other).Error)
	now := time.Now()
	require.NoError(t, h.persistBinding(user.ID, models.AcademicProviderUndergraduate, "SAME", now, "school_profile", "v1"))
	require.NoError(t, h.persistBinding(other.ID, models.AcademicProviderGraduate, "SAME", now, "school_profile", "v1"))
	available, err := hasStudentLoginIdentity(db, user)
	require.NoError(t, err)
	require.False(t, available)
	_, err = (&AuthHandler{db: db}).findLoginUser("SAME")
	require.Error(t, err)
}
