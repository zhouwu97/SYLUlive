package handlers

import (
	"fmt"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"net/http"
	"net/http/httptest"
	"shenliyuan/internal/models"
	"testing"
	"time"
)

func seedVerifiedStudent(t *testing.T, db *gorm.DB, user models.User) {
	t.Helper()
	require.NoError(t, db.AutoMigrate(&models.AcademicIdentityBinding{}))
	student := user.StudentID
	if student == "" {
		student = fmt.Sprint(user.ID)
	}
	require.NoError(t, db.Create(&models.AcademicIdentityBinding{UserID: user.ID,
		ProviderID: models.AcademicProviderUndergraduate, StudentID: student,
		VerifiedAt: time.Now(), VerificationMethod: models.AcademicVerificationMethodSchoolProfile, VerificationVersion: "v1"}).Error)
}

func seedAcademicConfig(t *testing.T, db *gorm.DB, user models.User) {
	t.Helper()
	require.NoError(t, db.Create(&models.AcademicAccountConfig{UserID: user.ID, ProviderID: models.AcademicProviderUndergraduate, StudentID: fmt.Sprint(user.ID), State: "active", Revision: 1}).Error)
}

func TestStudentPermissionsUseActiveConfigOnly(t *testing.T) {
	db := newCanteenTestDB(t)
	now := time.Now()
	user := models.User{StudentID: "2026000001", PasswordHash: "x", StudentVerifiedAt: &now}
	require.NoError(t, db.Create(&user).Error)
	check := func(want bool) {
		t.Helper()
		recorder := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(recorder)
		c.Set("user_id", user.ID)
		_, allowed := requireAcademicConfig(c, db, "评价")
		require.Equal(t, want, allowed)
		if !want {
			require.Equal(t, http.StatusForbidden, recorder.Code)
		}
		c, _ = gin.CreateTestContext(httptest.NewRecorder())
		c.Set("user_id", user.ID)
		_, allowed = (&ExamPaperHandler{db: db}).currentExamPaperUser(c)
		require.Equal(t, want, allowed)
	}
	check(false)
	seedVerifiedStudent(t, db, user)
	require.NoError(t, db.Model(&user).Update("student_verified_at", nil).Error)
	// 旧身份和凭据授权均不能代替有效配置。
	check(false)
	require.NoError(t, db.Model(&user).Updates(map[string]interface{}{"edu_authorized": true, "edu_bound": true}).Error)
	check(false)
	seedAcademicConfig(t, db, user)
	check(true)
	require.NoError(t, db.Where("user_id = ?", user.ID).Delete(&models.AcademicIdentityBinding{}).Error)
	require.NoError(t, db.Model(&user).Updates(map[string]interface{}{"student_verified_at": now, "edu_authorized": false, "edu_bound": false}).Error)
	check(true)
	require.NoError(t, db.Model(&models.AcademicAccountConfig{}).Where("user_id = ?", user.ID).Update("state", "deleted").Error)
	check(false)
	require.NoError(t, db.Model(&user).Update("role", models.RoleAdmin).Error)
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Set("user_id", user.ID)
	_, allowed := (&ExamPaperHandler{db: db}).currentExamPaperUser(c)
	require.True(t, allowed)
}
