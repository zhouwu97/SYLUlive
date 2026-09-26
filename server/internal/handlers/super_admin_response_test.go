package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

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
	if err := db.AutoMigrate(&models.User{}, &models.AcademicIdentityBinding{}); err != nil {
		t.Fatalf("migrate users: %v", err)
	}
	user := models.User{
		ID: 42, StudentID: "20260042", PasswordHash: "test", Nickname: "管理员目标",
		Role: models.RoleUser, CreditScore: 86, ReportCount: 2, EduAuthorized: true, EduBound: true,
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
	for _, field := range []string{"id", "student_id", "nickname", "avatar", "role", "credit_score", "report_count", "edu_bound", "student_verified", "academic_configured", "created_at"} {
		if _, exists := response[0][field]; !exists {
			t.Fatalf("admin response missing %s: %s", field, recorder.Body.String())
		}
	}
	if _, exists := response[0]["edu_student_id"]; exists {
		t.Fatalf("admin response leaked edu_student_id: %s", recorder.Body.String())
	}
}

func TestGetUsersSeparatesAcademicConfigurationFromIdentityAndAuthorization(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, test := range []struct {
		name       string
		configs    []models.AcademicAccountConfig
		configured bool
	}{
		{name: "没有配置"},
		{
			name: "有效配置",
			configs: []models.AcademicAccountConfig{
				{ProviderID: models.AcademicProviderUndergraduate, StudentID: "2408010446", State: "active", Revision: 1},
			},
			configured: true,
		},
		{
			name: "已删除配置",
			configs: []models.AcademicAccountConfig{
				{ProviderID: models.AcademicProviderUndergraduate, StudentID: "2408010446", State: "deleted", Revision: 2},
			},
		},
		{
			name: "空学号配置",
			configs: []models.AcademicAccountConfig{
				{ProviderID: models.AcademicProviderUndergraduate, StudentID: "  ", State: "active", Revision: 1},
			},
		},
		{
			name: "另一教务仍有有效配置",
			configs: []models.AcademicAccountConfig{
				{ProviderID: models.AcademicProviderUndergraduate, StudentID: "2408010446", State: "deleted", Revision: 2},
				{ProviderID: models.AcademicProviderGraduate, StudentID: "2606610446", State: "active", Revision: 1},
			},
			configured: true,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
			if err != nil {
				t.Fatalf("打开测试数据库失败: %v", err)
			}
			if err := db.AutoMigrate(&models.User{}, &models.AcademicIdentityBinding{}, &models.AcademicAccountConfig{}); err != nil {
				t.Fatalf("迁移测试数据库失败: %v", err)
			}
			user := models.User{ID: 446, PasswordHash: "test", Nickname: "本机教务用户", Role: models.RoleUser}
			if err := db.Create(&user).Error; err != nil {
				t.Fatalf("创建测试用户失败: %v", err)
			}
			for _, config := range test.configs {
				config.UserID = user.ID
				if err := db.Create(&config).Error; err != nil {
					t.Fatalf("创建教务配置失败: %v", err)
				}
			}

			recorder := httptest.NewRecorder()
			context, _ := gin.CreateTestContext(recorder)
			context.Request = httptest.NewRequest(http.MethodGet, "/api/super/users?search=446", nil)
			NewSuperAdminHandler(db).GetUsers(context)
			response := decodeInvitationResponse(t, recorder)
			if len(response) != 1 {
				t.Fatalf("用户数量错误: %s", recorder.Body.String())
			}
			if response[0]["academic_configured"] != test.configured {
				t.Fatalf("教务配置状态错误: %s", recorder.Body.String())
			}
			if response[0]["student_verified"] != false || response[0]["edu_bound"] != false || response[0]["student_id"] != "" {
				t.Fatalf("自报配置不能授予身份认证或旧教务授权: %s", recorder.Body.String())
			}
		})
	}
}

func TestGetUsersUsesVerifiedAcademicStudentIDAndSearch(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.AcademicIdentityBinding{}); err != nil {
		t.Fatalf("migrate users: %v", err)
	}
	user := models.User{ID: 436, PasswordHash: "test", Nickname: "念辞", Role: models.RoleUser}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	if err := db.Create(&models.AcademicIdentityBinding{
		UserID: 436, ProviderID: models.AcademicProviderUndergraduate, StudentID: "2408010115",
		VerifiedAt: time.Now(), VerificationMethod: models.AcademicVerificationMethodSchoolProfile, VerificationVersion: "v1",
	}).Error; err != nil {
		t.Fatalf("create academic identity: %v", err)
	}

	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/super/users?search=2408010115", nil)
	NewSuperAdminHandler(db).GetUsers(context)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response []map[string]interface{}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(response) != 1 || response[0]["student_id"] != "2408010115" {
		t.Fatalf("管理员用户列表未显示已验证教务学号: %s", recorder.Body.String())
	}
	if response[0]["student_verified"] != true || response[0]["edu_bound"] != false {
		t.Fatalf("管理员身份状态语义错误: %s", recorder.Body.String())
	}
}
