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

func newInvitationResponseTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.Invitation{}, &models.InvitationVote{}); err != nil {
		t.Fatalf("迁移测试数据库失败: %v", err)
	}
	return db
}

func createInvitationResponseTestUser(t *testing.T, db *gorm.DB, user models.User) {
	t.Helper()
	if user.PasswordHash == "" {
		user.PasswordHash = "test"
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("创建测试用户失败: %v", err)
	}
}

func decodeInvitationResponse(t *testing.T, recorder *httptest.ResponseRecorder) []map[string]interface{} {
	t.Helper()
	if recorder.Code != http.StatusOK {
		t.Fatalf("接口状态码 = %d，响应 = %s", recorder.Code, recorder.Body.String())
	}
	var response []map[string]interface{}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("解析接口响应失败: %v", err)
	}
	return response
}

func decodePaginatedResponse(t *testing.T, recorder *httptest.ResponseRecorder) map[string]interface{} {
	t.Helper()
	if recorder.Code != http.StatusOK {
		t.Fatalf("接口状态码 = %d，响应 = %s", recorder.Code, recorder.Body.String())
	}
	var response map[string]interface{}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("解析接口响应失败: %v", err)
	}
	return response
}

func TestGetMembersReturnsAdminFieldsWithoutUsingUserMarshalJSON(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newInvitationResponseTestDB(t)
	createInvitationResponseTestUser(t, db, models.User{
		ID: 1, StudentID: "admin-001", Nickname: "管理员", Role: models.RoleAdmin, Avatar: "admin.png",
	})
	createInvitationResponseTestUser(t, db, models.User{
		ID: 2, StudentID: "super-001", Nickname: "超级管理员", Role: models.RoleSuperAdmin, Avatar: "super.png",
	})
	createInvitationResponseTestUser(t, db, models.User{
		ID: 3, StudentID: "user-001", Nickname: "普通用户", Role: models.RoleUser,
	})

	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	NewInvitationHandler(db, "test-secret").GetMembers(context)
	response := decodeInvitationResponse(t, recorder)

	if len(response) != 2 {
		t.Fatalf("管理员数量 = %d，期望 2，响应 = %s", len(response), recorder.Body.String())
	}
	for _, member := range response {
		for _, field := range []string{"id", "nickname", "student_id", "role", "avatar"} {
			if _, exists := member[field]; !exists {
				t.Fatalf("管理员响应缺少 %s: %s", field, recorder.Body.String())
			}
		}
		if member["role"] != string(models.RoleAdmin) && member["role"] != string(models.RoleSuperAdmin) {
			t.Fatalf("管理员角色不正确: %s", recorder.Body.String())
		}
	}
}

func TestGetCandidatesReturnsStudentIDAndAvatar(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newInvitationResponseTestDB(t)
	createInvitationResponseTestUser(t, db, models.User{
		ID: 1, StudentID: "20260001", Nickname: "候选人", Role: models.RoleUser,
		CreditScore: 100, Avatar: "candidate.png",
	})
	createInvitationResponseTestUser(t, db, models.User{
		ID: 2, StudentID: "20260002", Nickname: "低信誉用户", Role: models.RoleUser,
		CreditScore: 80,
	})

	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/admin/candidates", nil)
	NewInvitationHandler(db, "test-secret").GetCandidates(context)
	response := decodePaginatedResponse(t, recorder)

	items, ok := response["items"].([]interface{})
	if !ok || len(items) != 1 {
		t.Fatalf("候选人数量 = %d，期望 1，响应 = %s", len(items), recorder.Body.String())
	}
	candidate, ok := items[0].(map[string]interface{})
	if !ok {
		t.Fatalf("候选人资料格式不正确: %s", recorder.Body.String())
	}
	if candidate["student_id"] != "20260001" || candidate["avatar"] != "candidate.png" {
		t.Fatalf("候选人学号或头像不正确: %s", recorder.Body.String())
	}
	if candidate["role"] != string(models.RoleUser) {
		t.Fatalf("候选人角色不正确: %s", recorder.Body.String())
	}
}

func TestGetCandidatesSupportsInternalIDSearch(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newInvitationResponseTestDB(t)
	createInvitationResponseTestUser(t, db, models.User{
		ID: 42, StudentID: "candidate-042", Nickname: "ID 候选人", Role: models.RoleUser,
		CreditScore: 100,
	})

	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/admin/candidates?q=42", nil)
	NewInvitationHandler(db, "test-secret").GetCandidates(context)
	response := decodePaginatedResponse(t, recorder)

	items, ok := response["items"].([]interface{})
	if !ok || len(items) != 1 {
		t.Fatalf("按内部 ID 搜索候选人失败: %s", recorder.Body.String())
	}
	candidate, ok := items[0].(map[string]interface{})
	if !ok || candidate["id"] != float64(42) {
		t.Fatalf("按内部 ID 搜索候选人失败: %s", recorder.Body.String())
	}
}

func TestGetApprovalListReturnsAdminDTOForNestedUsers(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newInvitationResponseTestDB(t)
	createInvitationResponseTestUser(t, db, models.User{
		ID: 1, StudentID: "candidate-001", Nickname: "候选人", Role: models.RoleUser,
		CreditScore: 96, EduBound: true,
	})
	createInvitationResponseTestUser(t, db, models.User{
		ID: 2, StudentID: "inviter-001", Nickname: "邀请人", Role: models.RoleAdmin,
	})
	invitation := models.Invitation{
		UserID: 1, InviterID: 2, Reason: "社区贡献", Status: models.InvitationStatusAccepted,
	}
	if err := db.Create(&invitation).Error; err != nil {
		t.Fatalf("创建邀请失败: %v", err)
	}

	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/super/invitations/pending", nil)
	context.Set("user_id", uint(2))
	NewInvitationHandler(db, "test-secret").GetApprovalList(context)
	response := decodeInvitationResponse(t, recorder)

	if len(response) != 1 {
		t.Fatalf("审批数量 = %d，响应 = %s", len(response), recorder.Body.String())
	}
	user, ok := response[0]["user"].(map[string]interface{})
	if !ok {
		t.Fatalf("候选人资料格式不正确: %s", recorder.Body.String())
	}
	for _, field := range []string{"id", "student_id", "credit_score", "edu_bound"} {
		if _, exists := user[field]; !exists {
			t.Fatalf("候选人资料缺少 %s: %s", field, recorder.Body.String())
		}
	}
	inviter, ok := response[0]["inviter"].(map[string]interface{})
	if !ok || inviter["student_id"] != "inviter-001" {
		t.Fatalf("邀请人资料不正确: %s", recorder.Body.String())
	}
}
