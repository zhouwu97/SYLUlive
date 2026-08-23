package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newUserPrivacyTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}, &models.CheckIn{}, &models.PushDevice{}); err != nil {
		t.Fatalf("migrate users: %v", err)
	}
	return db
}

func TestUpdatePushSettingsKeepsActiveDeviceWhenAnotherInstallationDisables(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newUserPrivacyTestDB(t)
	user := models.User{StudentID: "push-user", PasswordHash: "hash"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	handler := NewUserHandler(db)

	call := func(body string) *httptest.ResponseRecorder {
		recorder := httptest.NewRecorder()
		context, _ := gin.CreateTestContext(recorder)
		context.Request = httptest.NewRequest(http.MethodPut, "/api/user/push-settings", strings.NewReader(body))
		context.Request.Header.Set("Content-Type", "application/json")
		context.Set("user_id", user.ID)
		handler.UpdatePushSettings(context)
		return recorder
	}

	if recorder := call(`{"enabled":true,"installation_id":"device-a","registration_id":"rid-a","notice_version":"v1"}`); recorder.Code != http.StatusOK {
		t.Fatalf("enable status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if recorder := call(`{"enabled":false,"installation_id":"device-b","registration_id":"","notice_version":"v1"}`); recorder.Code != http.StatusOK || !strings.Contains(recorder.Body.String(), `"ignored":true`) {
		t.Fatalf("inactive disable status=%d body=%s", recorder.Code, recorder.Body.String())
	}

	var updated models.User
	if err := db.First(&updated, user.ID).Error; err != nil {
		t.Fatalf("load user: %v", err)
	}
	if !updated.PushDataProcessingEnabled || updated.PushInstallationID != "device-a" || updated.DeviceToken != "rid-a" {
		t.Fatalf("inactive device cleared active push state: %#v", updated)
	}

	if recorder := call(`{"enabled":false,"installation_id":"device-a","registration_id":"","notice_version":"v1"}`); recorder.Code != http.StatusOK {
		t.Fatalf("active disable status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if err := db.First(&updated, user.ID).Error; err != nil {
		t.Fatalf("reload user: %v", err)
	}
	if updated.PushDataProcessingEnabled || updated.PushInstallationID != "" || updated.DeviceToken != "" {
		t.Fatalf("active device did not clear push state: %#v", updated)
	}
}

func TestUserProfileResponsesEnforcePrivacyBoundary(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newUserPrivacyTestDB(t)
	user := models.User{
		StudentID:    "20260001",
		PasswordHash: "test",
		Nickname:     "公开用户",
		CreditScore:  87,
		EduStudentID: "edu-20260001",
		EduBound:     true,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	handler := NewUserHandler(db)

	publicRecorder := httptest.NewRecorder()
	publicContext, _ := gin.CreateTestContext(publicRecorder)
	publicContext.Request = httptest.NewRequest(http.MethodGet, "/api/user/1", nil)
	publicContext.Params = gin.Params{{Key: "id", Value: "1"}}
	handler.GetUserInfo(publicContext)

	if publicRecorder.Code != http.StatusOK {
		t.Fatalf("public status=%d body=%s", publicRecorder.Code, publicRecorder.Body.String())
	}
	var public map[string]interface{}
	if err := json.Unmarshal(publicRecorder.Body.Bytes(), &public); err != nil {
		t.Fatalf("decode public response: %v", err)
	}
	if public["id"] != float64(user.ID) {
		t.Fatalf("public response missing correct id: %s", publicRecorder.Body.String())
	}
	if public["credit_score"] != float64(user.CreditScore) {
		t.Fatalf("public response missing credit_score: %s", publicRecorder.Body.String())
	}
	for _, field := range []string{"student_id", "edu_student_id", "role"} {
		if _, exists := public[field]; exists {
			t.Fatalf("public response leaked %s: %s", field, publicRecorder.Body.String())
		}
	}

	selfRecorder := httptest.NewRecorder()
	selfContext, _ := gin.CreateTestContext(selfRecorder)
	selfContext.Request = httptest.NewRequest(http.MethodGet, "/api/user/profile", nil)
	selfContext.Set("user_id", user.ID)
	handler.GetProfile(selfContext)

	if selfRecorder.Code != http.StatusOK {
		t.Fatalf("self status=%d body=%s", selfRecorder.Code, selfRecorder.Body.String())
	}
	var self map[string]interface{}
	if err := json.Unmarshal(selfRecorder.Body.Bytes(), &self); err != nil {
		t.Fatalf("decode self response: %v", err)
	}
	if self["student_id"] != user.StudentID || self["edu_student_id"] != user.EduStudentID {
		t.Fatalf("self response lost account data: %s", selfRecorder.Body.String())
	}
}
