package handlers

import (
	"bytes"
	"encoding/json"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"net/http"
	"net/http/httptest"
	"shenliyuan/internal/models"
	"testing"
	"time"
)

func TestAcademicIdentityChangeAtomicAndVersioned(t *testing.T) {
	for _, scenario := range []string{"success", "version-race", "school-failure", "wrong-operation"} {
		t.Run(scenario, func(t *testing.T) {
			h, db, provider, user := newAcademicIdentityTestHandler(t)
			require.NoError(t, db.AutoMigrate(&models.AccountSecurityAuditLog{}, &models.EduCredentialCleanupJob{}))
			require.NoError(t, db.Model(&user).Updates(map[string]interface{}{
				"student_id": "OLD", "student_verified_at": time.Now(),
				"edu_student_id": "OLD", "edu_authorized": true, "edu_bound": true,
				"edu_password": "fixture-secret", "edu_cookie": "fixture-session",
			}).Error)
			old := models.AcademicIdentityBinding{UserID: user.ID, ProviderID: models.AcademicProviderUndergraduate, StudentID: "OLD", BindingVersion: 3, VerifiedAt: time.Now(), VerificationMethod: "fixture", VerificationVersion: "v1"}
			require.NoError(t, db.Create(&old).Error)
			router := academicIdentityRouter(h, user.ID)
			router.POST("/change/challenge", func(c *gin.Context) { c.Set("user_id", user.ID) }, h.CreateChangeChallenge)
			router.POST("/change", func(c *gin.Context) { c.Set("user_id", user.ID) }, h.Change)
			request := func(path string, body interface{}) *httptest.ResponseRecorder {
				encoded, err := json.Marshal(body)
				require.NoError(t, err)
				response := httptest.NewRecorder()
				router.ServeHTTP(response, httptest.NewRequest(http.MethodPost, path, bytes.NewReader(encoded)))
				return response
			}
			challengeResponse := request("/change/challenge", map[string]string{"provider_id": models.AcademicProviderGraduate, "student_id": "G20260001", "current_provider_id": old.ProviderID, "current_student_id": old.StudentID})
			require.Equal(t, http.StatusOK, challengeResponse.Code, challengeResponse.Body.String())
			var challenge map[string]interface{}
			require.NoError(t, json.Unmarshal(challengeResponse.Body.Bytes(), &challenge))
			token := challenge["challenge_token"].(string)
			claims, err := h.unsealChallenge(token)
			require.NoError(t, err)
			require.Equal(t, "change", claims.Operation)
			require.Equal(t, uint(3), claims.CurrentBindingVersion)
			payload := map[string]string{"provider_id": models.AcademicProviderGraduate, "student_id": "G20260001", "challenge_token": token, "captcha": "1234", "encrypted_password": "ciphertext", "school_public_key_fingerprint": "sha256:fixture-key"}
			path := "/change"
			if scenario == "version-race" {
				require.NoError(t, db.Model(&old).Update("binding_version", 4).Error)
			}
			if scenario == "school-failure" {
				provider.verifyErr = ErrAcademicProviderUnavailable
			}
			if scenario == "wrong-operation" {
				path = "/verify"
			}
			response := request(path, payload)
			var current models.AcademicIdentityBinding
			require.NoError(t, db.First(&current, old.ID).Error)
			if scenario == "success" {
				require.Equal(t, http.StatusOK, response.Code, response.Body.String())
				require.Equal(t, models.AcademicProviderGraduate, current.ProviderID)
				require.Equal(t, uint(4), current.BindingVersion)
				require.NotNil(t, current.ChangedAt)
				var auditCount int64
				require.NoError(t, db.Model(&models.AccountSecurityAuditLog{}).Count(&auditCount).Error)
				require.Equal(t, int64(1), auditCount)
				var updatedUser models.User
				require.NoError(t, db.First(&updatedUser, user.ID).Error)
				require.Nil(t, updatedUser.StudentVerifiedAt)
				require.False(t, updatedUser.EduAuthorized)
				require.Empty(t, updatedUser.EduPassword)
				require.Empty(t, updatedUser.EduCookie)
				require.True(t, updatedUser.EduCleanupPending)
				var cleanupCount int64
				require.NoError(t, db.Model(&models.EduCredentialCleanupJob{}).Where("user_id = ?", user.ID).Count(&cleanupCount).Error)
				require.Equal(t, int64(1), cleanupCount)
				require.Equal(t, http.StatusConflict, request("/change", payload).Code)
			} else {
				require.NotEqual(t, http.StatusOK, response.Code)
				require.Equal(t, old.ProviderID, current.ProviderID)
				require.Equal(t, old.StudentID, current.StudentID)
			}
		})
	}
}
