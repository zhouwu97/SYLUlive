package handlers

import (
	"encoding/json"
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

func newPrivacyTestHandler(t *testing.T) (*PrivacyHandler, *gorm.DB, models.User) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserFollow{}, &models.UserLegalConsent{}, &models.PersonalDataRequest{}, &models.AdminActionLog{}); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	passwordHash, err := bcrypt.GenerateFromPassword([]byte("password123"), bcrypt.MinCost)
	if err != nil {
		t.Fatalf("hash password: %v", err)
	}
	user := models.User{
		StudentID: "2026000001", PasswordHash: string(passwordHash), Nickname: "测试用户",
		QQ: "12345678", DeviceToken: "device-token", EduStudentID: "2026000001",
		EduPassword: "", EduCookie: "cookie", EduBound: false, EduCollege: "测试学院",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	return NewPrivacyHandler(db), db, user
}

func privacyContext(method, target, body string, userID uint) (*gin.Context, *httptest.ResponseRecorder) {
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(method, target, strings.NewReader(body))
	context.Request.Header.Set("Content-Type", "application/json")
	context.Set("user_id", userID)
	return context, recorder
}

func TestWithdrawConsentTakesEffectImmediately(t *testing.T) {
	handler, db, user := newPrivacyTestHandler(t)
	consent := models.UserLegalConsent{
		UserID: user.ID, Document: models.LegalDocumentPrivacyPolicy,
		Version: models.LegalDocumentVersion, AcceptedAt: user.CreatedAt,
	}
	if err := db.Create(&consent).Error; err != nil {
		t.Fatalf("create consent: %v", err)
	}

	context, recorder := privacyContext(http.MethodDelete, "/api/user/privacy/consents", `{"password":"password123","confirmed":true}`, user.ID)
	handler.WithdrawConsent(context)
	if recorder.Code != http.StatusOK {
		t.Fatalf("withdraw status=%d body=%s", recorder.Code, recorder.Body.String())
	}

	var updatedUser models.User
	if err := db.First(&updatedUser, user.ID).Error; err != nil {
		t.Fatalf("load user: %v", err)
	}
	if updatedUser.LegalConsentRevokedAt == nil || updatedUser.DeviceToken != "" || updatedUser.EduCookie != "" {
		t.Fatalf("withdrawal did not clear consent-dependent data: %#v", updatedUser)
	}
	var updatedConsent models.UserLegalConsent
	if err := db.First(&updatedConsent, consent.ID).Error; err != nil {
		t.Fatalf("load consent: %v", err)
	}
	if updatedConsent.RevokedAt == nil {
		t.Fatal("consent record was not marked as revoked")
	}
}

func TestWithdrawnConsentBlocksEduAuthenticationFlows(t *testing.T) {
	_, db, user := newPrivacyTestHandler(t)
	now := time.Now()
	if err := db.Model(&models.User{}).Where("id = ?", user.ID).
		Update("legal_consent_revoked_at", &now).Error; err != nil {
		t.Fatalf("mark consent withdrawn: %v", err)
	}
	handler := NewAuthHandler(db, "test-secret")

	loginContext, loginRecorder := privacyContext(
		http.MethodPost,
		"/api/login_edu",
		`{"student_id":"2026000001","edu_password":"edu-password","password":"password123"}`,
		0,
	)
	handler.LoginEdu(loginContext)
	if loginRecorder.Code != http.StatusForbidden || !strings.Contains(loginRecorder.Body.String(), "legal_consent_withdrawn") {
		t.Fatalf("login_edu status=%d body=%s", loginRecorder.Code, loginRecorder.Body.String())
	}

	forgotContext, forgotRecorder := privacyContext(
		http.MethodPost,
		"/api/forgot_password",
		`{"student_id":"2026000001","edu_password":"edu-password","new_password":"new-password123"}`,
		0,
	)
	handler.ForgotPassword(forgotContext)
	if forgotRecorder.Code != http.StatusForbidden || !strings.Contains(forgotRecorder.Body.String(), "legal_consent_withdrawn") {
		t.Fatalf("forgot_password status=%d body=%s", forgotRecorder.Code, forgotRecorder.Body.String())
	}
}

func TestPrivacyExportExcludesCredentials(t *testing.T) {
	handler, db, user := newPrivacyTestHandler(t)
	if err := recordLegalConsents(db, user.ID, LegalConsentInput{
		UserAgreementAccepted: true, PrivacyPolicyAccepted: true,
		CommunityRulesAccepted: true, MinorProtectionAccepted: true,
		ContentComplaintAccepted: true, SDKDisclosureAccepted: true,
	}, false); err != nil {
		t.Fatalf("record legal consents: %v", err)
	}
	context, recorder := privacyContext(http.MethodGet, "/api/user/privacy/export", "", user.ID)
	handler.ExportMyData(context)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	body := recorder.Body.String()
	for _, forbidden := range []string{"password_hash", "edu_password", "edu_cookie", "cookie"} {
		if strings.Contains(body, forbidden) {
			t.Fatalf("export leaked %q: %s", forbidden, body)
		}
	}
	var payload map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode export: %v", err)
	}
	if payload["account"] == nil {
		t.Fatalf("missing account export: %s", body)
	}
	if payload["legal_consents_active"] != true {
		t.Fatalf("missing active consent status: %s", body)
	}
}

func TestCancelAccountAnonymizesIdentityAndInvalidatesSession(t *testing.T) {
	handler, db, user := newPrivacyTestHandler(t)
	context, recorder := privacyContext(http.MethodDelete, "/api/user/account", `{"password":"password123","confirmed":true}`, user.ID)
	handler.CancelAccount(context)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var cancelled models.User
	if err := db.First(&cancelled, user.ID).Error; err != nil {
		t.Fatalf("load cancelled user: %v", err)
	}
	if cancelled.StudentID == user.StudentID || cancelled.QQ != "" || cancelled.DeviceToken != "" || cancelled.EduBound || cancelled.EduCookie != "" || cancelled.EduStudentID != "" {
		t.Fatalf("user was not fully anonymized: %#v", cancelled)
	}
	if cancelled.TokenVersion != user.TokenVersion+1 {
		t.Fatalf("token version=%d want %d", cancelled.TokenVersion, user.TokenVersion+1)
	}
	var request models.PersonalDataRequest
	if err := db.Where("user_id = ? AND request_type = ?", user.ID, models.PersonalDataRequestAccountCancelled).First(&request).Error; err != nil {
		t.Fatalf("missing cancellation audit: %v", err)
	}
}
