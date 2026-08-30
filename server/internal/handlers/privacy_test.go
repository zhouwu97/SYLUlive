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
	if err := db.AutoMigrate(&models.User{}, &models.UserFollow{}, &models.UserLegalConsent{}, &models.EmailVerificationChallenge{}, &models.PersonalDataRequest{}, &models.EduCredentialCleanupJob{}, &models.AdminActionLog{}, &models.PushDevice{}); err != nil {
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

func TestPrivacyRequestLifecycle(t *testing.T) {
	handler, db, user := newPrivacyTestHandler(t)
	createContext, createRecorder := privacyContext(http.MethodPost, "/api/user/privacy/requests", `{"request_type":"correction","detail":"请更正账户资料"}`, user.ID)
	handler.CreateRequest(createContext)
	if createRecorder.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", createRecorder.Code, createRecorder.Body.String())
	}
	var request models.PersonalDataRequest
	if err := db.First(&request).Error; err != nil {
		t.Fatalf("load request: %v", err)
	}

	admin := models.User{StudentID: "admin", PasswordHash: "hash", Nickname: "管理员", Role: models.RoleAdmin}
	if err := db.Create(&admin).Error; err != nil {
		t.Fatalf("create admin: %v", err)
	}
	handleContext, handleRecorder := privacyContext(http.MethodPut, "/api/admin/privacy/requests/1", `{"status":"completed","result":"导出文件已生成"}`, admin.ID)
	handleContext.Params = gin.Params{{Key: "id", Value: "1"}}
	handler.HandleRequest(handleContext)
	if handleRecorder.Code != http.StatusOK {
		t.Fatalf("handle status=%d body=%s", handleRecorder.Code, handleRecorder.Body.String())
	}

	listContext, listRecorder := privacyContext(http.MethodGet, "/api/user/privacy/requests", "", user.ID)
	handler.ListMyRequests(listContext)
	if listRecorder.Code != http.StatusOK || !strings.Contains(listRecorder.Body.String(), `"completed"`) {
		t.Fatalf("list status=%d body=%s", listRecorder.Code, listRecorder.Body.String())
	}
}

func TestPrivacyRequestsRejectDirectActions(t *testing.T) {
	handler, _, user := newPrivacyTestHandler(t)
	context, recorder := privacyContext(http.MethodPost, "/api/user/privacy/requests", `{"request_type":"access"}`, user.ID)
	handler.CreateRequest(context)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestPrivacyDataIsDirectAndRedacted(t *testing.T) {
	handler, db, user := newPrivacyTestHandler(t)
	if err := db.Model(&models.User{}).Where("id = ?", user.ID).Updates(map[string]interface{}{
		"avatar":     "https://example.test/private-avatar.png",
		"background": "https://example.test/private-background.png",
	}).Error; err != nil {
		t.Fatalf("update user: %v", err)
	}
	context, recorder := privacyContext(http.MethodGet, "/api/user/privacy/data", "", user.ID)
	handler.GetMyData(context)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	body := recorder.Body.String()
	if strings.Contains(body, "private-avatar.png") || strings.Contains(body, "private-background.png") {
		t.Fatalf("direct data leaked internal image URL: %s", body)
	}
	if !strings.Contains(body, `"avatar_set":true`) || !strings.Contains(body, `"background_set":true`) {
		t.Fatalf("direct data omitted asset state: %s", body)
	}
}

func TestWithdrawConsentClearsDependentCredentials(t *testing.T) {
	handler, db, user := newPrivacyTestHandler(t)
	now := time.Now().Add(-time.Minute)
	if err := db.Create(&models.UserLegalConsent{
		UserID: user.ID, Document: models.LegalDocumentPrivacyPolicy, Version: models.LegalDocumentVersion, AcceptedAt: now,
	}).Error; err != nil {
		t.Fatalf("create consent: %v", err)
	}
	context, recorder := privacyContext(http.MethodDelete, "/api/user/privacy/consents", `{"password":"password123","confirmed":true}`, user.ID)
	handler.WithdrawConsent(context)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var updated models.User
	if err := db.First(&updated, user.ID).Error; err != nil {
		t.Fatalf("load user: %v", err)
	}
	if updated.LegalConsentRevokedAt == nil || updated.DeviceToken != "" || updated.EduCookie != "" || updated.EduBound {
		t.Fatalf("withdraw did not clear restricted state: %#v", updated)
	}
	var consent models.UserLegalConsent
	if err := db.Where("user_id = ?", user.ID).First(&consent).Error; err != nil {
		t.Fatalf("load consent: %v", err)
	}
	if consent.RevokedAt == nil {
		t.Fatalf("consent was not revoked")
	}
}

func TestWithdrawConsentQueuesEduCredentialCleanupWithoutWaitingForRemoteService(t *testing.T) {
	handler, db, user := newPrivacyTestHandler(t)
	if err := db.Model(&models.User{}).Where("id = ?", user.ID).Updates(map[string]interface{}{
		"edu_bound":                    true,
		"edu_authorized":               true,
		"edu_session_state":            "active",
		"edu_authorization_generation": 1,
		"edu_student_id":               "2026000001",
		"edu_cookie":                   "cookie",
	}).Error; err != nil {
		t.Fatalf("set edu binding: %v", err)
	}
	context, recorder := privacyContext(http.MethodDelete, "/api/user/privacy/consents", `{"password":"password123","confirmed":true}`, user.ID)
	handler.WithdrawConsent(context)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}

	var updated models.User
	if err := db.First(&updated, user.ID).Error; err != nil {
		t.Fatalf("load user: %v", err)
	}
	if updated.LegalConsentRevokedAt == nil || updated.EduBound || updated.EduAuthorized ||
		updated.EduSessionState != "revoked" || updated.EduCookie != "" || updated.EduPassword != "" ||
		updated.StudentID != "2026000001" || updated.EduStudentID != "2026000001" || updated.EduCollege != "测试学院" {
		t.Fatalf("local revoke was not committed: %#v", updated)
	}
	var job models.EduCredentialCleanupJob
	if err := db.Where("user_id = ?", user.ID).First(&job).Error; err != nil {
		t.Fatalf("load cleanup job: %v", err)
	}
	if job.CompletedAt != nil || job.Attempts != 0 || job.NextAttemptAt.IsZero() {
		t.Fatalf("unexpected cleanup job: %#v", job)
	}
}

func TestPrivacyExportExcludesCredentials(t *testing.T) {
	handler, _, user := newPrivacyTestHandler(t)
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
