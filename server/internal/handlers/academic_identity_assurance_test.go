package handlers

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// seedAcademicAssuranceBinding 写入一条指定依据来源的身份记录。
func seedAcademicAssuranceBinding(t *testing.T, db *gorm.DB, userID uint, studentID, method string) {
	t.Helper()
	if err := db.Create(&models.AcademicIdentityBinding{
		UserID: userID, ProviderID: models.AcademicProviderUndergraduate, StudentID: studentID,
		VerifiedAt: time.Now(), VerificationMethod: method, VerificationVersion: "v1",
	}).Error; err != nil {
		t.Fatalf("创建身份记录失败: %v", err)
	}
}

func TestAdminCandidateSurfacesIgnoreLocalAcademicDeclaration(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newInvitationResponseTestDB(t)
	createInvitationResponseTestUser(t, db, models.User{
		ID: 437, Nickname: "本机声明用户", Role: models.RoleUser, CreditScore: 100,
	})
	seedAcademicAssuranceBinding(t, db, 437, "2408010999", models.AcademicVerificationMethodLocalDeclaration)

	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/admin/candidates?q=2408010999", nil)
	NewInvitationHandler(db, "test-secret").GetCandidates(context)
	items, ok := decodePaginatedResponse(t, recorder)["items"].([]interface{})
	if !ok {
		t.Fatalf("候选人响应格式不正确: %s", recorder.Body.String())
	}
	if len(items) != 0 {
		t.Fatalf("本机学号声明被当成可搜索的可信身份: %s", recorder.Body.String())
	}

	recorder = httptest.NewRecorder()
	context, _ = gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/admin/candidates/stats", nil)
	NewInvitationHandler(db, "test-secret").GetCandidatesStats(context)
	if stats := decodePaginatedResponse(t, recorder); stats["edu"] != float64(0) {
		t.Fatalf("本机学号声明被计入教务账号统计: %s", recorder.Body.String())
	}
}

func TestAdminCandidateSurfacesCountSchoolProfileIdentity(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newInvitationResponseTestDB(t)
	createInvitationResponseTestUser(t, db, models.User{
		ID: 438, Nickname: "学校核验用户", Role: models.RoleUser, CreditScore: 100,
	})
	seedAcademicAssuranceBinding(t, db, 438, "2408010998", models.AcademicVerificationMethodSchoolProfile)

	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/admin/candidates?q=2408010998", nil)
	NewInvitationHandler(db, "test-secret").GetCandidates(context)
	items, ok := decodePaginatedResponse(t, recorder)["items"].([]interface{})
	if !ok || len(items) != 1 {
		t.Fatalf("学校核验身份未进入候选人搜索: %s", recorder.Body.String())
	}

	recorder = httptest.NewRecorder()
	context, _ = gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/admin/candidates/stats", nil)
	NewInvitationHandler(db, "test-secret").GetCandidatesStats(context)
	if stats := decodePaginatedResponse(t, recorder); stats["edu"] != float64(1) {
		t.Fatalf("学校核验身份未计入教务账号统计: %s", recorder.Body.String())
	}
}
