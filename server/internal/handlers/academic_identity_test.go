package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

type academicIdentityFixtureProvider struct {
	profile    AcademicVerifiedProfile
	challenge  AcademicProviderChallenge
	lastVerify AcademicProviderVerifyRequest
	verifyErr  error
}

type undergraduateIdentityFixtureProvider struct {
	profile      AcademicVerifiedProfile
	lastPassword string
	verifyErr    error
}

func (p *undergraduateIdentityFixtureProvider) ProviderID() models.AcademicProviderID {
	return models.AcademicProviderUndergraduate
}

func (p *undergraduateIdentityFixtureProvider) PrepareChallenge(context.Context, uint, string) (AcademicProviderChallenge, error) {
	return AcademicProviderChallenge{Required: false, Type: "pre_verify"}, nil
}

func (p *undergraduateIdentityFixtureProvider) Verify(_ context.Context, request AcademicProviderVerifyRequest) (AcademicVerifiedProfile, error) {
	p.lastPassword = request.Password
	if p.verifyErr != nil {
		return AcademicVerifiedProfile{}, p.verifyErr
	}
	return p.profile, nil
}

func (p *academicIdentityFixtureProvider) ProviderID() models.AcademicProviderID {
	return models.AcademicProviderGraduate
}

func (p *academicIdentityFixtureProvider) PrepareChallenge(context.Context, uint, string) (AcademicProviderChallenge, error) {
	return p.challenge, nil
}

func (p *academicIdentityFixtureProvider) Verify(_ context.Context, request AcademicProviderVerifyRequest) (AcademicVerifiedProfile, error) {
	p.lastVerify = request
	if p.verifyErr != nil {
		return AcademicVerifiedProfile{}, p.verifyErr
	}
	return p.profile, nil
}

func newAcademicIdentityTestHandler(t *testing.T) (*AcademicIdentityHandler, *gorm.DB, *academicIdentityFixtureProvider, models.User) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.AcademicIdentityBinding{}, &models.AcademicIdentityChallenge{}))
	user := models.User{PasswordHash: "hash", AccountStatus: "active"}
	require.NoError(t, db.Create(&user).Error)
	provider := &academicIdentityFixtureProvider{
		profile: AcademicVerifiedProfile{ProviderID: models.AcademicProviderGraduate, StudentID: "G20260001", Name: "脱敏学生"},
		challenge: AcademicProviderChallenge{
			Required: true, Type: "image_captcha", Captcha: "base64-captcha",
			SchoolPublicKey:            "-----BEGIN PUBLIC KEY-----fixture-----END PUBLIC KEY-----",
			SchoolPublicKeyFingerprint: "sha256:fixture-key",
			ChallengeState:             []byte(`{"session_path":"/(S(temp))/"}`),
		},
	}
	handler, err := NewAcademicIdentityHandler(db, "test-academic-challenge-key")
	require.NoError(t, err)
	require.NoError(t, handler.SetProvider(provider))
	handler.now = time.Now
	return handler, db, provider, user
}

func academicIdentityRouter(handler *AcademicIdentityHandler, userID uint) *gin.Engine {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.POST("/challenge", func(c *gin.Context) { c.Set("user_id", userID) }, handler.CreateChallenge)
	router.POST("/verify", func(c *gin.Context) { c.Set("user_id", userID) }, handler.Verify)
	router.GET("/identities", func(c *gin.Context) { c.Set("user_id", userID) }, handler.List)
	return router
}

func TestAcademicIdentityChallengeIsBoundAndConsumedOnFirstVerify(t *testing.T) {
	handler, db, provider, user := newAcademicIdentityTestHandler(t)
	router := academicIdentityRouter(handler, user.ID)

	challengeBody := []byte(`{"provider_id":"sylu_graduate","student_id":"G20260001","redirect_uri":"/academic/verify"}`)
	challengeResponse := httptest.NewRecorder()
	router.ServeHTTP(challengeResponse, httptest.NewRequest(http.MethodPost, "/challenge", bytes.NewReader(challengeBody)))
	require.Equal(t, http.StatusOK, challengeResponse.Code, challengeResponse.Body.String())
	var challenge map[string]interface{}
	require.NoError(t, json.Unmarshal(challengeResponse.Body.Bytes(), &challenge))
	token, ok := challenge["challenge_token"].(string)
	require.True(t, ok)
	require.NotContains(t, token, "temp")
	require.Equal(t, true, challenge["challenge_required"])
	require.NotEmpty(t, challenge["school_public_key_fingerprint"])

	verifyPayload := map[string]string{
		"provider_id": "sylu_graduate", "student_id": "G20260001", "challenge_token": token,
		"captcha": "1234", "encrypted_password": "rsa-ciphertext",
		"school_public_key_fingerprint": "sha256:fixture-key",
	}
	encoded, err := json.Marshal(verifyPayload)
	require.NoError(t, err)
	verifyResponse := httptest.NewRecorder()
	router.ServeHTTP(verifyResponse, httptest.NewRequest(http.MethodPost, "/verify", bytes.NewReader(encoded)))
	require.Equal(t, http.StatusOK, verifyResponse.Code, verifyResponse.Body.String())
	require.Equal(t, "rsa-ciphertext", provider.lastVerify.EncryptedPassword)
	require.Equal(t, []byte(`{"session_path":"/(S(temp))/"}`), provider.lastVerify.ChallengeState)

	var binding models.AcademicIdentityBinding
	require.NoError(t, db.Where("user_id = ?", user.ID).First(&binding).Error)
	require.Equal(t, models.AcademicProviderGraduate, binding.ProviderID)
	require.Equal(t, "G20260001", binding.StudentID)

	secondResponse := httptest.NewRecorder()
	router.ServeHTTP(secondResponse, httptest.NewRequest(http.MethodPost, "/verify", bytes.NewReader(encoded)))
	require.Equal(t, http.StatusConflict, secondResponse.Code, secondResponse.Body.String())
	var count int64
	require.NoError(t, db.Model(&models.AcademicIdentityBinding{}).Where("user_id = ?", user.ID).Count(&count).Error)
	require.Equal(t, int64(1), count)
}

func TestAcademicIdentityWrongFingerprintConsumesChallenge(t *testing.T) {
	handler, _, _, user := newAcademicIdentityTestHandler(t)
	router := academicIdentityRouter(handler, user.ID)
	challengeResponse := httptest.NewRecorder()
	router.ServeHTTP(challengeResponse, httptest.NewRequest(http.MethodPost, "/challenge", bytes.NewBufferString(`{"provider_id":"sylu_graduate","student_id":"G20260001"}`)))
	require.Equal(t, http.StatusOK, challengeResponse.Code)
	var challenge map[string]interface{}
	require.NoError(t, json.Unmarshal(challengeResponse.Body.Bytes(), &challenge))
	token, ok := challenge["challenge_token"].(string)
	require.True(t, ok)
	payload := map[string]string{
		"provider_id": "sylu_graduate", "student_id": "G20260001", "challenge_token": token,
		"encrypted_password": "cipher", "school_public_key_fingerprint": "sha256:wrong",
	}
	encoded, _ := json.Marshal(payload)
	first := httptest.NewRecorder()
	router.ServeHTTP(first, httptest.NewRequest(http.MethodPost, "/verify", bytes.NewReader(encoded)))
	require.Equal(t, http.StatusUnauthorized, first.Code)
	payload["school_public_key_fingerprint"] = "sha256:fixture-key"
	encoded, _ = json.Marshal(payload)
	second := httptest.NewRecorder()
	router.ServeHTTP(second, httptest.NewRequest(http.MethodPost, "/verify", bytes.NewReader(encoded)))
	require.Equal(t, http.StatusConflict, second.Code, second.Body.String())
}

func TestAcademicIdentityRejectsProviderProfileMismatch(t *testing.T) {
	handler, db, provider, user := newAcademicIdentityTestHandler(t)
	provider.profile.StudentID = "G20260002"
	router := academicIdentityRouter(handler, user.ID)
	challengeResponse := httptest.NewRecorder()
	router.ServeHTTP(challengeResponse, httptest.NewRequest(http.MethodPost, "/challenge", bytes.NewBufferString(`{"provider_id":"sylu_graduate","student_id":"G20260001"}`)))
	require.Equal(t, http.StatusOK, challengeResponse.Code)
	var challenge map[string]interface{}
	require.NoError(t, json.Unmarshal(challengeResponse.Body.Bytes(), &challenge))
	token, ok := challenge["challenge_token"].(string)
	require.True(t, ok)
	verifyPayload := map[string]string{
		"provider_id": "sylu_graduate", "student_id": "G20260001", "challenge_token": token,
		"captcha": "1234", "encrypted_password": "rsa-ciphertext",
		"school_public_key_fingerprint": "sha256:fixture-key",
	}
	encoded, err := json.Marshal(verifyPayload)
	require.NoError(t, err)
	verifyResponse := httptest.NewRecorder()
	router.ServeHTTP(verifyResponse, httptest.NewRequest(http.MethodPost, "/verify", bytes.NewReader(encoded)))
	require.Equal(t, http.StatusUnauthorized, verifyResponse.Code, verifyResponse.Body.String())
	require.Contains(t, verifyResponse.Body.String(), "ACADEMIC_IDENTITY_MISMATCH")
	var bindingCount int64
	require.NoError(t, db.Model(&models.AcademicIdentityBinding{}).Count(&bindingCount).Error)
	require.Zero(t, bindingCount)
}

func TestAcademicIdentityMissingCiphertextStillConsumesChallenge(t *testing.T) {
	handler, _, _, user := newAcademicIdentityTestHandler(t)
	router := academicIdentityRouter(handler, user.ID)
	challengeResponse := httptest.NewRecorder()
	router.ServeHTTP(challengeResponse, httptest.NewRequest(http.MethodPost, "/challenge", bytes.NewBufferString(`{"provider_id":"sylu_graduate","student_id":"G20260001"}`)))
	require.Equal(t, http.StatusOK, challengeResponse.Code)
	var challenge map[string]interface{}
	require.NoError(t, json.Unmarshal(challengeResponse.Body.Bytes(), &challenge))
	token, ok := challenge["challenge_token"].(string)
	require.True(t, ok)
	payload := map[string]string{
		"provider_id": "sylu_graduate", "student_id": "G20260001", "challenge_token": token,
		"school_public_key_fingerprint": "sha256:fixture-key",
	}
	encoded, _ := json.Marshal(payload)
	first := httptest.NewRecorder()
	router.ServeHTTP(first, httptest.NewRequest(http.MethodPost, "/verify", bytes.NewReader(encoded)))
	require.Equal(t, http.StatusBadRequest, first.Code, first.Body.String())
	payload["encrypted_password"] = "rsa-ciphertext"
	encoded, _ = json.Marshal(payload)
	second := httptest.NewRecorder()
	router.ServeHTTP(second, httptest.NewRequest(http.MethodPost, "/verify", bytes.NewReader(encoded)))
	require.Equal(t, http.StatusConflict, second.Code, second.Body.String())
}

func TestAcademicIdentityGraduateDoesNotOverwriteLegacyUndergraduateFields(t *testing.T) {
	_, db, _, user := newAcademicIdentityTestHandler(t)
	now := time.Now()
	require.NoError(t, db.Model(&models.User{}).Where("id = ?", user.ID).Updates(map[string]interface{}{
		"student_id": "2026000001", "student_verified_at": now, "academic_provider_id": models.AcademicProviderUndergraduate,
	}).Error)
	require.NoError(t, persistAcademicIdentityBinding(db, user.ID, models.AcademicProviderGraduate, "G20260001", now, "fixture", "v1"))
	var stored models.User
	require.NoError(t, db.First(&stored, user.ID).Error)
	require.Equal(t, "2026000001", stored.StudentID)
	require.Equal(t, models.AcademicProviderID(models.AcademicProviderUndergraduate), stored.AcademicProviderID)
}

func TestUndergraduateVerifyOnlyPersistsIdentityWithoutLegacyCredentials(t *testing.T) {
	handler, db, _, user := newAcademicIdentityTestHandler(t)
	provider := &undergraduateIdentityFixtureProvider{profile: AcademicVerifiedProfile{
		ProviderID: models.AcademicProviderUndergraduate, StudentID: "2026000001", Name: "本科学生",
	}}
	require.NoError(t, handler.SetProvider(provider))
	router := academicIdentityRouter(handler, user.ID)
	body := []byte(`{"provider_id":"sylu_undergraduate","student_id":"2026000001","password":"transient-password"}`)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/verify", bytes.NewReader(body)))
	require.Equal(t, http.StatusOK, recorder.Code, recorder.Body.String())
	require.Equal(t, "transient-password", provider.lastPassword)
	var binding models.AcademicIdentityBinding
	require.NoError(t, db.Where("user_id = ?", user.ID).First(&binding).Error)
	require.Equal(t, models.AcademicProviderUndergraduate, binding.ProviderID)
	require.Equal(t, "2026000001", binding.StudentID)
	var stored models.User
	require.NoError(t, db.First(&stored, user.ID).Error)
	require.Empty(t, stored.StudentID)
	require.False(t, stored.EduAuthorized)
	require.Equal(t, "unbound", stored.EduSessionState)
	var attempts int64
	require.NoError(t, db.Model(&models.AcademicIdentityChallenge{}).Where("provider_id = ?", models.AcademicProviderUndergraduate).Count(&attempts).Error)
	require.Equal(t, int64(1), attempts)
}

func TestUndergraduatePreVerifyRejectsEchoOnlyStudentID(t *testing.T) {
	_, err := parseUndergraduatePreVerifyResponse([]byte(`{"success":true,"student_id":"2026000001","name":"本科学生"}`))
	require.ErrorIs(t, err, ErrAcademicIdentityUnverified)
	result, err := parseUndergraduatePreVerifyResponse([]byte(`{"success":true,"student_id":"echo","school_verified_student_id":"2026000001","name":"本科学生"}`))
	require.NoError(t, err)
	require.Equal(t, "2026000001", result.SchoolVerifiedStudentID)
}

func TestLegacyUndergraduateBindProjectsProviderIdentity(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.AcademicIdentityBinding{}, &models.EduCredentialCleanupJob{}))
	now := time.Now()
	user := models.User{PasswordHash: "hash", AccountStatus: "active", EduBindingState: "pending", EduBindingPendingGeneration: 1, EduBindingPendingStudentID: "2026000001", EduAuthorizationGeneration: 0}
	require.NoError(t, db.Create(&user).Error)
	result := &eduBindResult{Success: true, StudentID: "2026000001", Grade: "2026", College: "计算机学院", Major: "软件工程"}
	require.NoError(t, updateUserEduBinding(db, user.ID, "2026000001", result, 1, false))
	var binding models.AcademicIdentityBinding
	require.NoError(t, db.Where("user_id = ?", user.ID).First(&binding).Error)
	require.Equal(t, models.AcademicProviderUndergraduate, binding.ProviderID)
	require.Equal(t, "2026000001", binding.StudentID)
	var stored models.User
	require.NoError(t, db.First(&stored, user.ID).Error)
	require.Equal(t, models.AcademicProviderID(models.AcademicProviderUndergraduate), stored.AcademicProviderID)
	require.WithinDuration(t, now, binding.VerifiedAt, 2*time.Second)
}

func TestLegacyUndergraduateBindRejectsMismatchedSchoolProfile(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.AcademicIdentityBinding{}, &models.EduCredentialCleanupJob{}))
	user := models.User{PasswordHash: "hash", AccountStatus: "active", EduBindingState: "pending", EduBindingPendingGeneration: 1, EduBindingPendingStudentID: "2026000001"}
	require.NoError(t, db.Create(&user).Error)
	err = updateUserEduBinding(db, user.ID, "2026000001", &eduBindResult{Success: true, StudentID: "2026000002"}, 1, false)
	require.ErrorIs(t, err, errEduStudentProfileMismatch)
	var bindingCount int64
	require.NoError(t, db.Model(&models.AcademicIdentityBinding{}).Count(&bindingCount).Error)
	require.Zero(t, bindingCount)
}

func TestGraduateProviderCannotUseLegacyUndergraduateBindRoute(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}))
	user := models.User{PasswordHash: "hash", AccountStatus: "active"}
	require.NoError(t, db.Create(&user).Error)
	handler := NewEduHandler(db)
	router := gin.New()
	router.POST("/bind", func(c *gin.Context) { c.Set("user_id", user.ID) }, handler.BindEdu)
	body := []byte(`{"provider_id":"sylu_graduate","student_id":"2026000001","password":"never-forwarded","edu_data_consent_accepted":true}`)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/bind", bytes.NewReader(body)))
	require.Equal(t, http.StatusBadRequest, recorder.Code)
	require.Contains(t, recorder.Body.String(), "ACADEMIC_PROVIDER_ROUTE_UNSUPPORTED")
}

func TestLegacyUndergraduateBindKeepsMissingProviderIDCompatible(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}))
	user := models.User{PasswordHash: "hash", AccountStatus: "active"}
	require.NoError(t, db.Create(&user).Error)
	handler := NewEduHandler(db)
	router := gin.New()
	router.POST("/bind", func(c *gin.Context) { c.Set("user_id", user.ID) }, handler.BindEdu)
	// 旧客户端不发送 provider_id；请求应进入原有授权门禁，而不是被新 Provider 路由规则拒绝。
	body := []byte(`{"student_id":"2026000001","password":"legacy-password"}`)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/bind", bytes.NewReader(body)))
	require.Equal(t, http.StatusBadRequest, recorder.Code)
	require.Contains(t, recorder.Body.String(), "EDU_DATA_CONSENT_REQUIRED")
	require.NotContains(t, recorder.Body.String(), "ACADEMIC_PROVIDER_ROUTE_UNSUPPORTED")
}
