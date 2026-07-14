package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestGetUsersReturnsAdminDTOAndSupportsInternalIDSearch(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}); err != nil {
		t.Fatalf("migrate users: %v", err)
	}
	user := models.User{
		ID: 42, StudentID: "20260042", PasswordHash: "test", Nickname: "管理员目标",
		Role: models.RoleUser, CreditScore: 86, ReportCount: 2, EduBound: true,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}

	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/super/users?search=42", nil)
	NewSuperAdminHandler(db).GetUsers(context)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response []map[string]interface{}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(response) != 1 {
		t.Fatalf("unexpected response: %s", recorder.Body.String())
	}
	for _, field := range []string{"id", "student_id", "nickname", "avatar", "role", "credit_score", "report_count", "edu_bound", "created_at"} {
		if _, exists := response[0][field]; !exists {
			t.Fatalf("admin response missing %s: %s", field, recorder.Body.String())
		}
	}
	if _, exists := response[0]["edu_student_id"]; exists {
		t.Fatalf("admin response leaked edu_student_id: %s", recorder.Body.String())
	}
}
