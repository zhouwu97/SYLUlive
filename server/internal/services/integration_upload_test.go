package services

import (
	"context"
	"github.com/stretchr/testify/require"
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
