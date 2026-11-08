package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func TestMyAcademicContentEndpointKeepsOwnerScopeAndLegacyShape(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open("file:academic_content_handler?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.Teacher{}, &models.TeacherRating{},
		&models.CourseSubject{}, &models.CourseEvaluationSubmission{}, &models.Post{}))
	owner := models.User{StudentID: "content-owner", Nickname: "本人", PasswordHash: "test"}
	other := models.User{StudentID: "content-other", Nickname: "其他", PasswordHash: "test"}
	require.NoError(t, db.Create(&owner).Error)
	require.NoError(t, db.Create(&other).Error)
	teacher := models.Teacher{Name: "教师", Course: "课程"}
	require.NoError(t, db.Create(&teacher).Error)
	for _, user := range []models.User{owner, other} {
		require.NoError(t, db.Create(&models.TeacherRating{UserID: user.ID, TeacherID: teacher.ID,
			Star: 5, Comment: user.Nickname}).Error)
	}
	require.NoError(t, db.Create(&models.CourseEvaluationSubmission{UserID: owner.ID, DedupKey: "content",
		CourseName: "课程提交", TeacherName: "教师", Star: 4, Status: "pending"}).Error)
	require.NoError(t, db.Create(&models.Post{AuthorID: owner.ID, BoardID: models.BoardShuitie, Status: models.PostStatusNormal}).Error)
	require.NoError(t, db.Create(&models.Post{AuthorID: owner.ID, BoardID: models.BoardMarket, Status: models.PostStatusSold}).Error)
	h := NewCourseEvaluationHandler(db)
	request := func(query string, loggedIn bool) *httptest.ResponseRecorder {
		r := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(r)
		c.Request = httptest.NewRequest(http.MethodGet, "/api/user/course-evaluations"+query, nil)
		if loggedIn {
			c.Set("user_id", owner.ID)
			c.Set("role", "admin")
		}
		h.ListMine(c)
		return r
	}
	legacy := request("", true)
	require.Equal(t, http.StatusOK, legacy.Code)
	var legacyPage map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(legacy.Body.Bytes(), &legacyPage))
	require.NotContains(t, legacyPage, "content_counts")
	var legacyItems []services.SubmissionView
	require.NoError(t, json.Unmarshal(legacyPage["items"], &legacyItems))
	require.Len(t, legacyItems, 1)
	preview, err := services.UnifyAcademicEvaluations(context.Background(), db, services.AcademicUnificationOptions{})
	require.NoError(t, err)
	_, err = services.UnifyAcademicEvaluations(context.Background(), db, services.AcademicUnificationOptions{Apply: true, BackupConfirmed: true, ExpectedPlan: preview.Fingerprint})
	require.NoError(t, err)

	unified := request("?include_teacher_ratings=true&include_content_counts=true&user_id=2", true)
	require.Equal(t, http.StatusOK, unified.Code, unified.Body.String())
	var page services.AcademicContentPage
	require.NoError(t, json.Unmarshal(unified.Body.Bytes(), &page))
	require.True(t, page.IncludesTeacherRatings)
	require.Equal(t, int64(2), page.Total)
	require.Len(t, page.Items, 2)
	require.Equal(t, int64(4), page.ContentCounts.Count)
	for _, item := range page.Items {
		require.Equal(t, owner.ID, item.UserID, "管理员也不能通过 query 改读他人私有内容")
	}
	require.Equal(t, http.StatusForbidden, request("?include_teacher_ratings=true", false).Code)
	require.Equal(t, http.StatusBadRequest, request("?include_teacher_ratings=true&cursor=invalid", true).Code)
}
