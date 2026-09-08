package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"net/http/httptest"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"testing"
)

func TestAcademicConfigRevisionIsolationAndReplay(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.AcademicIdentityBinding{}, &models.AcademicAccountConfig{}, &models.AcademicConfigReceipt{}))
	users := []models.User{{PasswordHash: "x"}, {PasswordHash: "y"}}
	require.NoError(t, db.Create(&users).Error)
	user := users[0].ID
	r := gin.New()
	r.Use(func(c *gin.Context) { c.Set("user_id", user) })
	h := NewAcademicAccountConfigHandler(db)
	r.GET("/configs", h.List)
	r.PUT("/configs/:provider", h.Mutate)
	r.DELETE("/configs/:provider", h.Mutate)
	request := func(method, provider, op, body string, status int) models.AcademicAccountConfig {
		req := httptest.NewRequest(method, "/configs/"+provider, bytes.NewBufferString(body))
		req.Header.Set("Idempotency-Key", op)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		require.Equal(t, status, w.Code, w.Body.String())
		var response struct {
			Config models.AcademicAccountConfig `json:"config"`
		}
		require.NoError(t, json.Unmarshal(w.Body.Bytes(), &response))
		return response.Config
	}
	u := models.AcademicProviderUndergraduate
	g := models.AcademicProviderGraduate
	first := request("PUT", u, "first", `{"student_id":"Same-ID","expected_revision":0}`, 200)
	require.EqualValues(t, 1, first.Revision)
	request("PUT", g, "graduate", `{"student_id":"Same-ID","expected_revision":0}`, 200)
	deleted := request("DELETE", u, "remove", `{"expected_revision":1}`, 200)
	require.EqualValues(t, 2, deleted.Revision)
	recreated := request("PUT", u, "new", `{"student_id":"Other-ID","expected_revision":2}`, 200)
	require.EqualValues(t, 3, recreated.Revision)
	replay := request("DELETE", u, "remove", `{"expected_revision":1}`, 200)
	require.EqualValues(t, 2, replay.Revision)
	request("PUT", u, "stale", `{"student_id":"Old-ID","expected_revision":1}`, 409)
	request("PUT", u, "first", `{"student_id":"Modified","expected_revision":0}`, 409)
	request("PUT", u, "secret", `{"student_id":"ID","expected_revision":3,"password":"secret"}`, 400)
	request("PUT", "unknown", "provider", `{"student_id":"ID","expected_revision":0}`, 400)
	user = users[1].ID
	request("PUT", u, "first", `{"student_id":"Same-ID","expected_revision":0}`, 200)
	wrongUser := httptest.NewRequest("PUT", "/configs/"+g, bytes.NewBufferString(`{"student_id":"WrongOwner","expected_revision":0}`))
	wrongUser.Header.Set("Idempotency-Key", "wrong-owner")
	wrongUser.Header.Set("X-Expected-App-User", fmt.Sprint(users[0].ID))
	rejected := httptest.NewRecorder()
	r.ServeHTTP(rejected, wrongUser)
	require.Equal(t, 409, rejected.Code)
	require.Contains(t, rejected.Body.String(), "APP_USER_CHANGED")
	var count int64
	require.NoError(t, db.Model(&models.AcademicIdentityBinding{}).Count(&count).Error)
	require.Zero(t, count)
	var actual models.AcademicAccountConfig
	require.NoError(t, db.First(&actual, first.ID).Error)
	require.Equal(t, "Other-ID", actual.StudentID)
	// 重启回填不得复活已删除配置。
	user = users[0].ID
	request("DELETE", u, "final", fmt.Sprintf(`{"expected_revision":%d}`, actual.Revision), 200)
	require.NoError(t, services.SeedAcademicAccountConfigs(db))
	require.NoError(t, db.First(&actual, first.ID).Error)
	require.Equal(t, "deleted", actual.State)
}
