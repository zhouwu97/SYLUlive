package handlers

import (
	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"testing"
	"time"
)

func TestFixedLoginAliasSurvivesAcademicChangeAndUnbind(t *testing.T) {
	for _, provider := range []string{models.AcademicProviderUndergraduate, models.AcademicProviderGraduate} {
		t.Run(provider, func(t *testing.T) {
			h, db, _, user := newAcademicIdentityTestHandler(t)
			require.NoError(t, db.AutoMigrate(&models.UserLegalConsent{}, &models.AccountSecurityAuditLog{}, &models.EduCredentialCleanupJob{}))
			now := time.Now()
			require.NoError(t, h.persistBinding(user.ID, provider, "ORIGINAL", now, "school_profile", "v1"))
			require.NoError(t, services.MigrateAccountLoginAliases(db))
			var binding models.AcademicIdentityBinding
			require.NoError(t, db.First(&binding).Error)
			target := models.AcademicProviderGraduate
			if provider == target {
				target = models.AcademicProviderUndergraduate
			}
			require.NoError(t, h.changeBinding(academicChallengeClaims{UserID: user.ID, CurrentBindingID: binding.ID, CurrentBindingVersion: binding.BindingVersion, CurrentProviderID: provider, CurrentStudentID: "ORIGINAL", ProviderID: target, StudentID: "NEW"}, now))
			auth := &AuthHandler{db: db}
			found, err := auth.findLoginUser("ORIGINAL")
			require.NoError(t, err)
			require.Equal(t, user.ID, found.ID)
			_, err = auth.findLoginUser("NEW")
			require.Error(t, err)
			require.NoError(t, db.Where("user_id = ?", user.ID).Delete(&models.AcademicIdentityBinding{}).Error)
			require.NoError(t, services.MigrateAccountLoginAliases(db))
			found, err = auth.findLoginUser("ORIGINAL")
			require.NoError(t, err)
			require.Equal(t, user.ID, found.ID)
			profile, err := selfUserResponseForDB(db, user)
			require.NoError(t, err)
			require.Equal(t, "ORIGINAL", profile.LoginAccount)
			require.Contains(t, profile.LoginMethods, "student_id")
			require.False(t, profile.StudentVerified)
			available, err := hasStudentLoginIdentity(db, user)
			require.NoError(t, err)
			require.True(t, available)
			require.NoError(t, db.Model(&user).Updates(map[string]interface{}{"email": "test@example.com", "email_verified_at": now}).Error)
			require.NoError(t, db.First(&user, user.ID).Error)
			profile, err = selfUserResponseForDB(db, user)
			require.NoError(t, err)
			require.Equal(t, maskEmail(user.Email), profile.LoginAccount)
		})
	}
}

func TestFixedLoginAliasRejectsAmbiguityAndDoesNotSeedNewBindings(t *testing.T) {
	h, db, _, user := newAcademicIdentityTestHandler(t)
	other := models.User{AccountStatus: "active", PasswordHash: "hash"}
	require.NoError(t, db.Create(&other).Error)
	now := time.Now()
	require.NoError(t, h.persistBinding(user.ID, models.AcademicProviderUndergraduate, "SAME", now, "school_profile", "v1"))
	require.NoError(t, h.persistBinding(other.ID, models.AcademicProviderGraduate, "SAME", now, "school_profile", "v1"))
	require.NoError(t, services.MigrateAccountLoginAliases(db))
	_, err := (&AuthHandler{db: db}).findLoginUser("SAME")
	require.Error(t, err)
	aliases, err := services.AvailableAccountLoginAliases(db, user.ID)
	require.NoError(t, err)
	require.Empty(t, aliases)
	require.NoError(t, h.persistBinding(user.ID, models.AcademicProviderGraduate, "LATER", now, "school_profile", "v1"))
	require.NoError(t, services.MigrateAccountLoginAliases(db))
	_, err = (&AuthHandler{db: db}).findLoginUser("LATER")
	require.Error(t, err)
	require.NoError(t, db.Model(&other).Update("account_status", "cancelled").Error)
	found, err := (&AuthHandler{db: db}).findLoginUser("SAME")
	require.NoError(t, err)
	require.Equal(t, user.ID, found.ID)
}
