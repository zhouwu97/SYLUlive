package handlers

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"shenliyuan/internal/models"
)

func TestAdminAcademicDisplayPrefersTrustedIdentityThenLatestActiveConfig(t *testing.T) {
	db := newInvitationResponseTestDB(t)
	users := []models.User{
		{ID: 1, StudentID: "legacy-1", Nickname: "有可信身份"},
		{ID: 2, StudentID: "legacy-2", Nickname: "多个配置"},
		{ID: 3, StudentID: "legacy-3", Nickname: "已解绑"},
	}
	for _, user := range users {
		createInvitationResponseTestUser(t, db, user)
	}
	now := time.Now().UTC()
	for _, config := range []models.AcademicAccountConfig{
		{UserID: 1, ProviderID: models.AcademicProviderUndergraduate, StudentID: "declared-1", State: "active", UpdatedAt: now},
		{UserID: 2, ProviderID: models.AcademicProviderUndergraduate, StudentID: "older-2", State: "active", UpdatedAt: now.Add(-time.Hour)},
		{UserID: 2, ProviderID: models.AcademicProviderGraduate, StudentID: "latest-2", State: "active", UpdatedAt: now},
		{UserID: 3, ProviderID: models.AcademicProviderUndergraduate, StudentID: "deleted-3", State: "deleted", UpdatedAt: now},
	} {
		if err := db.Create(&config).Error; err != nil {
			t.Fatal(err)
		}
	}
	for _, binding := range []models.AcademicIdentityBinding{
		{UserID: 1, ProviderID: models.AcademicProviderUndergraduate, StudentID: "trusted-1", VerifiedAt: now, VerificationMethod: models.AcademicVerificationMethodSchoolProfile},
		{UserID: 2, ProviderID: models.AcademicProviderUndergraduate, StudentID: "local-2", VerifiedAt: now, VerificationMethod: models.AcademicVerificationMethodLocalDeclaration},
	} {
		if err := db.Create(&binding).Error; err != nil {
			t.Fatal(err)
		}
	}
	identities, err := loadAdminAcademicStudentIDs(db, users)
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		user      models.User
		studentID string
		verified  bool
	}{{users[0], "trusted-1", true}, {users[1], "latest-2", false}, {users[2], "legacy-3", false}} {
		if adminStudentID(test.user, identities) != test.studentID || adminStudentVerified(test.user, identities) != test.verified {
			t.Fatalf("用户 %d 的管理摘要错误: %+v", test.user.ID, identities)
		}
	}
}

func TestGetCandidatesStatsCountsExistingAcademicAccountOwnersOnce(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newInvitationResponseTestDB(t)
	for id := uint(1); id <= 7; id++ {
		createInvitationResponseTestUser(t, db, models.User{
			ID: id, Nickname: "统计用户", Role: models.RoleUser,
			EduAuthorized: id == 3, EduBound: id == 3,
		})
	}
	now := time.Now().UTC()
	for _, config := range []models.AcademicAccountConfig{
		{UserID: 1, ProviderID: models.AcademicProviderUndergraduate, StudentID: "active-1", State: "active"},
		{UserID: 1, ProviderID: models.AcademicProviderGraduate, StudentID: "active-other-1", State: "active"},
		{UserID: 2, ProviderID: models.AcademicProviderUndergraduate, StudentID: "active-2", State: "active"},
		{UserID: 4, ProviderID: models.AcademicProviderUndergraduate, StudentID: "deleted-4", State: "deleted"},
		{UserID: 5, ProviderID: models.AcademicProviderUndergraduate, StudentID: " ", State: "active"},
		{UserID: 99, ProviderID: models.AcademicProviderUndergraduate, StudentID: "orphan-99", State: "active"},
	} {
		if err := db.Create(&config).Error; err != nil {
			t.Fatal(err)
		}
	}
	for _, binding := range []models.AcademicIdentityBinding{
		{UserID: 2, ProviderID: models.AcademicProviderUndergraduate, StudentID: "trusted-2", VerifiedAt: now, VerificationMethod: models.AcademicVerificationMethodSchoolProfile},
		{UserID: 6, ProviderID: models.AcademicProviderUndergraduate, StudentID: "declared-6", VerifiedAt: now, VerificationMethod: models.AcademicVerificationMethodLocalDeclaration},
		{UserID: 7, ProviderID: models.AcademicProviderUndergraduate, StudentID: "trusted-7", VerifiedAt: now, VerificationMethod: models.AcademicVerificationMethodLegacyMigration},
		{UserID: 98, ProviderID: models.AcademicProviderUndergraduate, StudentID: "orphan-98", VerifiedAt: now, VerificationMethod: models.AcademicVerificationMethodSchoolProfile},
	} {
		if err := db.Create(&binding).Error; err != nil {
			t.Fatal(err)
		}
	}
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/admin/candidates/stats", nil)
	NewInvitationHandler(db, "test-secret").GetCandidatesStats(context)
	stats := decodePaginatedResponse(t, recorder)
	if stats["total"] != float64(7) || stats["edu"] != float64(4) || stats["other"] != float64(3) {
		t.Fatalf("配置/身份/授权应按现存用户去重，删除、空值和孤儿记录不得计入: %s", recorder.Body.String())
	}
}

func TestGetCandidatesSearchesConfiguredStudentIDAndKeepsEligibilityFilter(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newInvitationResponseTestDB(t)
	for _, user := range []models.User{
		{ID: 901, Nickname: "普通候选人", Role: models.RoleUser},
		{ID: 902, Nickname: "已有管理员", Role: models.RoleAdmin},
	} {
		createInvitationResponseTestUser(t, db, user)
		if err := db.Create(&models.AcademicAccountConfig{
			UserID: user.ID, ProviderID: models.AcademicProviderUndergraduate, StudentID: "configured-shared", State: "active",
		}).Error; err != nil {
			t.Fatal(err)
		}
	}
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/admin/candidates?q=configured-shared", nil)
	NewInvitationHandler(db, "test-secret").GetCandidates(context)
	response := decodePaginatedResponse(t, recorder)
	items := response["items"].([]interface{})
	if len(items) != 1 {
		t.Fatalf("配置学号搜索不得绕过候选人筛选: %s", recorder.Body.String())
	}
	candidate := items[0].(map[string]interface{})
	if candidate["id"] != float64(901) || candidate["student_id"] != "configured-shared" || candidate["student_verified"] != false {
		t.Fatalf("配置搜索/展示不得授予身份: %s", recorder.Body.String())
	}
}

func TestAdminAcademicConfigWorksWithoutLegacyIdentityTable(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newInvitationResponseTestDB(t)
	if err := db.Migrator().DropTable(&models.AcademicIdentityBinding{}); err != nil {
		t.Fatal(err)
	}
	createInvitationResponseTestUser(t, db, models.User{ID: 901, Nickname: "新配置用户", Role: models.RoleUser})
	if err := db.Create(&models.AcademicAccountConfig{
		UserID: 901, ProviderID: models.AcademicProviderUndergraduate, StudentID: "configured-901", State: "active",
	}).Error; err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/super/users?search=configured-901", nil)
	NewSuperAdminHandler(db).GetUsers(context)
	users := decodeInvitationResponse(t, recorder)
	if len(users) != 1 || users[0]["student_id"] != "configured-901" || users[0]["student_verified"] != false {
		t.Fatalf("无旧身份表时有效配置仍应支持学号展示及搜索: %s", recorder.Body.String())
	}
	var count int64
	if err := withAdminAcademicAccounts(db).Count(&count).Error; err != nil || count != 1 {
		t.Fatalf("无旧身份表时配置统计错误: count=%d err=%v", count, err)
	}
}
