package services

import (
	"context"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"testing"
	"time"
)

func TestIntegrationUploadedGradesConsentVersionDeleteAndNoScopeExpansion(t *testing.T) {
	db, auth, b, _ := personalIntegrationFixture(t)
	// 本机同步不要求服务器继续保管学校远程登录凭据。
	require.NoError(t, db.Model(&models.User{}).Where("id = ?", b.OwnerID).Update("edu_authorized", false).Error)
	input := IntegrationGradesUpload{Consent: true, FetchedAt: auth.Now(), Year: "2026", Semester: 3, Grades: []IntegrationGrade{{CourseName: "浏览器本机课程", Score: "合格", Credits: 2}}}
	require.NoError(t, auth.StoreUploadedGrades(context.Background(), b.OwnerID, input))
	result, err := auth.ReadPersonal(context.Background(), b, "grades", 0, 20)
	require.NoError(t, err)
	require.Equal(t, false, result["live_query"])
	require.Equal(t, true, result["is_partial"])
	require.Contains(t, result["grades"].([]map[string]interface{})[0]["course_name"], "浏览器本机课程")
	input.FetchedAt = input.FetchedAt.Add(-time.Hour)
	require.Error(t, auth.StoreUploadedGrades(context.Background(), b.OwnerID, input))
	input.FetchedAt = auth.Now()
	input.Consent = false
	require.Error(t, auth.StoreUploadedGrades(context.Background(), b.OwnerID, input))
	require.NoError(t, auth.DeleteUploadedGrades(context.Background(), b.OwnerID))
	_, err = auth.ReadPersonal(context.Background(), b, "grades", 0, 20)
	require.Error(t, err)
	var current models.IntegrationBinding
	require.NoError(t, db.First(&current, "id = ?", b.ID).Error)
	require.Equal(t, b.Scopes, current.Scopes)
}

func TestIntegrationIdentityInvalidationErasesOnlyOwnUploadedGrades(t *testing.T) {
	db, auth, first, second := personalIntegrationFixture(t)
	input := IntegrationGradesUpload{Consent: true, FetchedAt: auth.Now(), Year: "2026", Semester: 3, Grades: []IntegrationGrade{{CourseName: "身份清理测试", Score: "合格", Credits: 2}}}
	for _, id := range []uint{first.OwnerID, second.OwnerID} {
		require.NoError(t, auth.StoreUploadedGrades(context.Background(), id, input))
	}
	require.NoError(t, db.Transaction(func(tx *gorm.DB) error {
		return InvalidateUserIntegrations(tx, first.OwnerID, auth.Now())
	}))
	var count int64
	require.NoError(t, db.Model(&models.PersonalUploadedSnapshot{}).Where("user_id = ? AND snapshot_type = ?", first.OwnerID, "integration_grades").Count(&count).Error)
	require.Zero(t, count, "注销、撤回协议或教务换绑清除旧身份上传副本")
	require.NoError(t, db.Model(&models.PersonalUploadedSnapshot{}).Where("user_id = ? AND snapshot_type = ?", second.OwnerID, "integration_grades").Count(&count).Error)
	require.EqualValues(t, 1, count, "不能清除其他用户资料")
}
