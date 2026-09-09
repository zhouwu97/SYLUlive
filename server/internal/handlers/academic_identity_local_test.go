package handlers

import (
	"bytes"
	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"net/http/httptest"
	"shenliyuan/internal/models"
	"testing"
)

func TestLocalIdentityBindingUsesAppUserAndNeverSchoolProvider(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.AcademicIdentityBinding{}))
	users := []models.User{{ID: 1, PasswordHash: "x"}, {ID: 2, PasswordHash: "x"}}
	require.NoError(t, db.Create(&users).Error)
	// 不配置任何学校 Provider 或挑战密钥，本机声明仍应完成登记。
	h := &AcademicIdentityHandler{db: db}
	call := func(user uint, body string) int {
		recorder := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(recorder)
		c.Set("user_id", user)
		c.Request = httptest.NewRequest("POST", "/student-identity/bind", bytes.NewBufferString(body))
		h.BindLocal(c)
		return recorder.Code
	}
	body := `{"provider_id":"sylu_undergraduate","student_id":"2403000001","verification_method":"local_academic_login"}`
	require.Equal(t, 200, call(1, body))
	require.Equal(t, 200, call(1, body))
	require.Equal(t, 409, call(2, body))
	require.Equal(t, 401, call(0, body))
	require.Equal(t, 400, call(1, `{"provider_id":"sylu_undergraduate","student_id":"2403000001","verification_method":"local_academic_login","password":"must-not-upload"}`))
	require.Equal(t, 400, call(1, `{"provider_id":"sylu_undergraduate","student_id":"2403000001","verification_method":"local_academic_login","user_id":2}`))
	var binding models.AcademicIdentityBinding
	require.NoError(t, db.First(&binding).Error)
	require.Equal(t, uint(1), binding.UserID)
	require.Equal(t, "local_academic_login", binding.VerificationMethod)
	require.False(t, binding.VerifiedAt.IsZero())
	var count int64
	require.NoError(t, db.Model(&binding).Count(&count).Error)
	require.EqualValues(t, 1, count)
	allowed, err := models.HasVerifiedAcademicIdentity(db, 1)
	require.NoError(t, err)
	require.True(t, allowed)
}
