package handlers

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestQQVerificationCredentialCanBeConsumedByRegistration(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}); err != nil {
		t.Fatalf("migrate database: %v", err)
	}

	qq := "12345678"
	verifyCodeStore.Lock()
	verifyCodeStore.codes = map[string]verifyCodeRecord{
		qq: {Code: "123456", SentAt: time.Now(), ExpiresAt: time.Now().Add(time.Minute)},
	}
	verifyCodeStore.verified = make(map[string]time.Time)
	verifyCodeStore.ipSends = make(map[string][]time.Time)
	verifyCodeStore.Unlock()
	t.Cleanup(func() {
		verifyCodeStore.Lock()
		verifyCodeStore.codes = make(map[string]verifyCodeRecord)
		verifyCodeStore.verified = make(map[string]time.Time)
		verifyCodeStore.ipSends = make(map[string][]time.Time)
		verifyCodeStore.Unlock()
	})

	handler := NewAuthHandler(db, "test-jwt-secret")
	verifyRecorder := httptest.NewRecorder()
	verifyContext, _ := gin.CreateTestContext(verifyRecorder)
	verifyContext.Request = httptest.NewRequest(http.MethodPost, "/verify_code", strings.NewReader(`{"qq":"12345678","code":"123456"}`))
	verifyContext.Request.Header.Set("Content-Type", "application/json")
	handler.VerifyCode(verifyContext)
	if verifyRecorder.Code != http.StatusOK {
		t.Fatalf("verify code status=%d body=%s", verifyRecorder.Code, verifyRecorder.Body.String())
	}

	registerRecorder := httptest.NewRecorder()
	registerContext, _ := gin.CreateTestContext(registerRecorder)
	registerContext.Request = httptest.NewRequest(http.MethodPost, "/register", strings.NewReader(`{
		"qq":"12345678","code":"000000","password":"password123",
		"user_agreement_accepted":true,"privacy_policy_accepted":true,
		"community_rules_accepted":true,"minor_protection_accepted":true,
		"content_complaint_accepted":true,"sdk_disclosure_accepted":true
	}`))
	registerContext.Request.Header.Set("Content-Type", "application/json")
	handler.Register(registerContext)
	if registerRecorder.Code != http.StatusCreated {
		t.Fatalf("register status=%d body=%s", registerRecorder.Code, registerRecorder.Body.String())
	}
	if isQQVerified(qq) {
		t.Fatal("registration should consume the one-time QQ verification credential")
	}
	var consentCount int64
	if err := db.Model(&models.UserLegalConsent{}).Count(&consentCount).Error; err != nil {
		t.Fatalf("count legal consents: %v", err)
	}
	if consentCount != 6 {
		t.Fatalf("legal consent count=%d, want 6", consentCount)
	}
}

func TestRegistrationRejectsMissingLegalConsent(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	handler := NewAuthHandler(db, "test-jwt-secret")
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodPost, "/register", strings.NewReader(`{"qq":"12345678","code":"123456","password":"password123"}`))
	context.Request.Header.Set("Content-Type", "application/json")
	handler.Register(context)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestAcceptLegalConsentsRestoresRevokedAccount(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	passwordHash, err := bcrypt.GenerateFromPassword([]byte("password123"), bcrypt.MinCost)
	if err != nil {
		t.Fatalf("hash password: %v", err)
	}
	revokedAt := time.Now().Add(-time.Minute)
	user := models.User{
		StudentID: "2026000001", PasswordHash: string(passwordHash), Nickname: "测试用户",
		LegalConsentRevokedAt: &revokedAt,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	if err := db.Create(&models.UserLegalConsent{
		UserID: user.ID, Document: models.LegalDocumentPrivacyPolicy, Version: models.LegalDocumentVersion,
		AcceptedAt: revokedAt, RevokedAt: &revokedAt,
	}).Error; err != nil {
		t.Fatalf("create revoked consent: %v", err)
	}

	handler := NewAuthHandler(db, "test-jwt-secret")
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodPost, "/legal-consents", strings.NewReader(`{
		"user_agreement_accepted":true,"privacy_policy_accepted":true,
		"community_rules_accepted":true,"minor_protection_accepted":true,
		"content_complaint_accepted":true,"sdk_disclosure_accepted":true
	}`))
	context.Request.Header.Set("Content-Type", "application/json")
	context.Set("user_id", user.ID)
	handler.AcceptLegalConsents(context)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var updated models.User
	if err := db.First(&updated, user.ID).Error; err != nil {
		t.Fatalf("reload user: %v", err)
	}
	if updated.LegalConsentRevokedAt != nil {
		t.Fatalf("consent revocation was not cleared")
	}
	state, err := models.LegalConsentStateForUser(db, updated)
	if err != nil || state != models.LegalConsentStateActive {
		t.Fatalf("state=%q err=%v", state, err)
	}
}
