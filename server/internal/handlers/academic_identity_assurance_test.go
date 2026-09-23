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

func TestAdminCandidateSurfacesPreserveLegacyEligibilityUntilAudit(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newInvitationResponseTestDB(t)
	createInvitationResponseTestUser(t, db, models.User{
		ID: 437, Nickname: "本机声明用户", Role: models.RoleUser, CreditScore: 100,
	})
	seedAcademicAssuranceBinding(t, db, 437, "2408010999", models.AcademicVerificationMethodLocalDeclaration)
	createInvitationResponseTestUser(t, db, models.User{
		ID: 439, Nickname: "历史回填用户", Role: models.RoleUser, CreditScore: 100,
	})
	seedAcademicAssuranceBinding(t, db, 439, "2408010997", models.AcademicVerificationMethodLegacyMigration)

	for _, testCase := range []struct {
		studentID string
		wantCount int
	}{
		{studentID: "2408010999", wantCount: 0},
		{studentID: "2408010997", wantCount: 1},
	} {
		recorder := httptest.NewRecorder()
		context, _ := gin.CreateTestContext(recorder)
		context.Request = httptest.NewRequest(http.MethodGet, "/api/admin/candidates?q="+testCase.studentID, nil)
		NewInvitationHandler(db, "test-secret").GetCandidates(context)
		items, ok := decodePaginatedResponse(t, recorder)["items"].([]interface{})
		if !ok {
			t.Fatalf("候选人响应格式不正确: %s", recorder.Body.String())
		}
		if len(items) != testCase.wantCount {
			t.Fatalf("身份 %s 的兼容准入结果错误，got=%d want=%d: %s", testCase.studentID, len(items), testCase.wantCount, recorder.Body.String())
		}
	}

	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/admin/candidates/stats", nil)
	NewInvitationHandler(db, "test-secret").GetCandidatesStats(context)
	if stats := decodePaginatedResponse(t, recorder); stats["edu"] != float64(1) {
		t.Fatalf("历史回填身份的兼容统计状态错误: %s", recorder.Body.String())
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

func TestAcademicBindingPayloadMarksLegacyAsInherited(t *testing.T) {
	payload := academicBindingPayload(models.AcademicIdentityBinding{
		UserID: 440, ProviderID: models.AcademicProviderUndergraduate, StudentID: "2408010996",
		VerifiedAt: time.Now(), VerificationMethod: models.AcademicVerificationMethodLegacyMigration,
		VerificationVersion: "v1",
	})
	if payload["verified"] != true {
		t.Fatalf("历史回填身份的兼容准入状态未保留: %#v", payload)
	}
	if payload["assurance_level"] != models.AcademicAssuranceLegacyInherited {
		t.Fatalf("历史回填身份没有返回独立状态: %#v", payload)
	}
}
