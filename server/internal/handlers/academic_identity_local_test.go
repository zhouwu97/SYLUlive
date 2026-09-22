package handlers

import (
	"bytes"
	"encoding/json"
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
	call := func(user uint, body string) (int, []byte) {
		recorder := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(recorder)
		c.Set("user_id", user)
		c.Request = httptest.NewRequest("POST", "/student-identity/bind", bytes.NewBufferString(body))
		h.BindLocal(c)
		return recorder.Code, recorder.Body.Bytes()
	}
	body := `{"provider_id":"sylu_undergraduate","student_id":"2403000001","verification_method":"local_academic_login"}`
	status, payload := call(1, body)
	require.Equal(t, 200, status)
	var declaration map[string]any
	require.NoError(t, json.Unmarshal(payload, &declaration))
	require.Equal(t, false, declaration["verified"])
	require.Equal(t, "local_declaration", declaration["assurance_level"])
	status, _ = call(1, body)
	require.Equal(t, 200, status)
	// 未验证声明不占用其他账号的全局身份名额。
	status, _ = call(2, body)
	require.Equal(t, 200, status)
	status, _ = call(0, body)
	require.Equal(t, 401, status)
	status, _ = call(1, `{"provider_id":"sylu_undergraduate","student_id":"2403000001","verification_method":"local_academic_login","password":"must-not-upload"}`)
	require.Equal(t, 400, status)
	status, _ = call(1, `{"provider_id":"sylu_undergraduate","student_id":"2403000001","verification_method":"local_academic_login","user_id":2}`)
	require.Equal(t, 400, status)
	var count int64
	require.NoError(t, db.Model(&models.AcademicIdentityBinding{}).Count(&count).Error)
	require.EqualValues(t, 0, count)
	allowed, err := models.HasVerifiedAcademicIdentity(db, 1)
	require.NoError(t, err)
	require.False(t, allowed)
}
