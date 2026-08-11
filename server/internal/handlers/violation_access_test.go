package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func newViolationAccessTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserViolation{}); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

func callViolationHandler(t *testing.T, handler gin.HandlerFunc, method, path string, userID uint, id string) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(recorder)
	c.Request = httptest.NewRequest(method, path, nil)
	c.Set("user_id", userID)
	if id != "" {
		c.Params = gin.Params{{Key: "id", Value: id}}
	}
	handler(c)
	return recorder
}

func TestViolationsAreScopedToCurrentUserAndAppealIsIdempotent(t *testing.T) {
	db := newViolationAccessTestDB(t)
	users := []models.User{
		{ID: 1, StudentID: "violation-a", PasswordHash: "hash", Nickname: "A"},
		{ID: 2, StudentID: "violation-b", PasswordHash: "hash", Nickname: "B"},
	}
	if err := db.Create(&users).Error; err != nil {
		t.Fatalf("create users: %v", err)
	}
	violations := []models.UserViolation{
		{ID: 11, UserID: 1, BoardID: 1, Reason: "A reason", Action: "mute"},
		{ID: 22, UserID: 2, BoardID: 1, Reason: "B reason", Action: "mute"},
	}
	if err := db.Create(&violations).Error; err != nil {
		t.Fatalf("create violations: %v", err)
	}

	handler := NewTeacherHandler(db)
	list := callViolationHandler(t, handler.GetViolations, http.MethodGet, "/api/violations?user_id=2", 1, "")
	if list.Code != http.StatusOK {
		t.Fatalf("list status=%d body=%s", list.Code, list.Body.String())
	}
	var own []models.UserViolation
	if err := json.Unmarshal(list.Body.Bytes(), &own); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	if len(own) != 1 || own[0].ID != 11 {
		t.Fatalf("user-scoped violations=%+v", own)
	}

	foreignAppeal := callViolationHandler(t, handler.AppealViolation, http.MethodPost, "/api/violations/22/appeal", 1, "22")
	if foreignAppeal.Code != http.StatusNotFound {
		t.Fatalf("foreign appeal status=%d body=%s", foreignAppeal.Code, foreignAppeal.Body.String())
	}
	ownAppeal := callViolationHandler(t, handler.AppealViolation, http.MethodPost, "/api/violations/11/appeal", 1, "11")
	if ownAppeal.Code != http.StatusOK {
		t.Fatalf("own appeal status=%d body=%s", ownAppeal.Code, ownAppeal.Body.String())
	}
	repeatedAppeal := callViolationHandler(t, handler.AppealViolation, http.MethodPost, "/api/violations/11/appeal", 1, "11")
	if repeatedAppeal.Code != http.StatusConflict {
		t.Fatalf("repeated appeal status=%d body=%s", repeatedAppeal.Code, repeatedAppeal.Body.String())
	}

	adminList := callViolationHandler(t, handler.GetAdminViolations, http.MethodGet, "/api/admin/violations", 99, "")
	if adminList.Code != http.StatusOK {
		t.Fatalf("admin list status=%d body=%s", adminList.Code, adminList.Body.String())
	}
	var all []models.UserViolation
	if err := json.Unmarshal(adminList.Body.Bytes(), &all); err != nil {
		t.Fatalf("decode admin list: %v", err)
	}
	if len(all) != 2 {
		t.Fatalf("admin violations=%+v", all)
	}
}
