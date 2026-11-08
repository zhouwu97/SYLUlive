package services

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

func unifyAcademicFixture(t *testing.T, db *gorm.DB) *AcademicUnificationReport {
	t.Helper()
	preview, err := UnifyAcademicEvaluations(context.Background(), db, AcademicUnificationOptions{})
	require.NoError(t, err)
	result, err := UnifyAcademicEvaluations(context.Background(), db, AcademicUnificationOptions{Apply: true, BackupConfirmed: true, ExpectedPlan: preview.Fingerprint})
	require.NoError(t, err)
	require.True(t, result.Applied)
	return result
}

func TestAcademicContentUsesCanonicalRecordsForBothEntrances(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	require.NoError(t, db.AutoMigrate(&models.Post{}))
	svc := NewCourseEvaluationService(db)
	owner := createCourseEvalUser(t, db, "canonical-owner")
	other := createCourseEvalUser(t, db, "canonical-other")
	subject := createCourseEvalSubject(t, db, "气排球文化与健康", true)
	teacher := createCourseEvalTeacher(t, db, "朱俊", subject.Name, subject.ID, true)
	at := time.Date(2026, 5, 30, 8, 0, 0, 0, time.UTC)
	legacy := models.TeacherRating{ID: 1, UserID: owner.ID, TeacherID: teacher.ID, Star: 5, Comment: strings.Repeat("完整旧评价", 90), CreatedAt: at, UpdatedAt: at, HelpfulCount: 7}
	require.NoError(t, db.Create(&legacy).Error)
	otherRating := models.TeacherRating{UserID: other.ID, TeacherID: teacher.ID, Star: 4, Comment: "其他账号"}
	require.NoError(t, db.Create(&otherRating).Error)
	course := models.CourseEvaluationSubmission{ID: 1, UserID: owner.ID, DedupKey: "course-other", CourseName: "马克思主义基本原理", TeacherName: "周吾诠", Star: 1, Comment: "课表入口", Status: models.CourseEvaluationStatusPending}
	require.NoError(t, db.Create(&course).Error)
	_, err := svc.ListAcademicContent(owner.ID, 20, "", false)
	assertCourseEvaluationCode(t, err, CodeCourseEvaluationSubjectUnavailable)
	var before int64
	require.NoError(t, db.Model(&models.CourseEvaluationSubmission{}).Count(&before).Error)
	require.Equal(t, int64(1), before, "GET 不得回填历史")
	unifyAcademicFixture(t, db)
	for _, p := range []models.Post{{AuthorID: owner.ID, BoardID: models.BoardShuitie, Status: models.PostStatusNormal}, {AuthorID: owner.ID, BoardID: models.BoardMarket, Status: models.PostStatusSold}} {
		require.NoError(t, db.Create(&p).Error)
	}
	page, err := svc.ListAcademicContent(owner.ID, 20, "", true)
	require.NoError(t, err)
	require.Equal(t, int64(2), page.Total)
	require.Len(t, page.Items, 2)
	require.Equal(t, int64(4), page.ContentCounts.Count)
	var masterID uint
	for _, item := range page.Items {
		require.Equal(t, owner.ID, item.UserID)
		if item.Source == models.CourseEvaluationSourceLegacyTeacher {
			require.NotEqual(t, legacy.ID, item.ID, "公开评价 ID 不能冒充主记录 ID")
			masterID = item.ID
			require.Equal(t, legacy.Comment, item.Comment)
			require.Equal(t, at, item.CreatedAt)
			require.Equal(t, legacy.ID, *item.TeacherRatingID)
		}
	}
	require.NotZero(t, masterID)
	all, err := svc.ListMine(owner.ID, 50, "")
	require.NoError(t, err)
	require.Len(t, all.Items, 2, "旧列表同样读取统一主记录")
	updated, err := svc.RateVerifiedTeacher(owner.ID, teacher.ID, 4, "教师入口修改")
	require.NoError(t, err)
	require.Equal(t, masterID, updated.ID)
	require.Equal(t, 2, updated.Revision)
	updated, err = svc.Update(owner.ID, masterID, UpdateCourseEvaluationInput{CourseName: subject.Name, CourseSubjectID: &subject.ID, TeacherName: teacher.Name, TeacherID: &teacher.ID, Star: 3, Comment: "课表入口再修改", Revision: updated.Revision})
	require.NoError(t, err)
	require.Equal(t, masterID, updated.ID)
	var projection models.TeacherRating
	require.NoError(t, db.First(&projection, legacy.ID).Error)
	require.Equal(t, 3, projection.Star)
	require.Equal(t, updated.Comment, projection.Comment)
	require.Equal(t, 7, projection.HelpfulCount)
	require.Equal(t, masterID, *projection.CourseEvaluationSubmissionID)
	resolved, err := svc.Resolve(owner.ID, subject.Name, teacher.Name)
	require.NoError(t, err)
	require.Equal(t, masterID, resolved.Submission.ID)
	_, err = svc.Submit(owner.ID, CreateCourseEvaluationInput{CourseName: subject.Name, TeacherName: teacher.Name, TeacherID: &teacher.ID, CourseSubjectID: &subject.ID, Star: 5})
	assertCourseEvaluationCode(t, err, CodeCourseEvaluationAlreadyExists)
	_, err = svc.ListAcademicContent(0, 20, "", false)
	assertCourseEvaluationCode(t, err, CodeCourseEvaluationForbidden)
}

func TestAcademicContentCanonicalCursorNoDuplicateAtEqualTimes(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	svc := NewCourseEvaluationService(db)
	owner := createCourseEvalUser(t, db, "canonical-cursor")
	at := time.Date(2026, 11, 4, 0, 0, 0, 0, time.UTC)
	for i := uint(1); i <= 8; i++ {
		require.NoError(t, db.Create(&models.CourseEvaluationSubmission{ID: i, UserID: owner.ID, DedupKey: fmt.Sprintf("cursor-%d", i), CourseName: "课程", TeacherName: "教师", CreatedAt: at}).Error)
	}
	seen := map[uint]bool{}
	cursor := ""
	for attempt := 0; attempt < 10; attempt++ {
		page, err := svc.ListAcademicContent(owner.ID, 1, cursor, false)
		require.NoError(t, err)
		require.Len(t, page.Items, 1)
		item := page.Items[0]
		require.False(t, seen[item.ID])
		seen[item.ID] = true
		if attempt == 0 {
			require.NoError(t, db.Create(&models.CourseEvaluationSubmission{UserID: owner.ID, DedupKey: "new-top", CourseName: "新课程", TeacherName: "教师", CreatedAt: at.Add(time.Hour)}).Error)
		}
		if !page.HasMore {
			break
		}
		require.NotEqual(t, cursor, page.NextCursor)
		cursor = page.NextCursor
	}
	require.Len(t, seen, 8)
	for _, bad := range []string{"bad!", "e30", "MQ"} {
		_, err := svc.ListAcademicContent(owner.ID, 1, bad, false)
		assertCourseEvaluationCode(t, err, CodeInvalidCourseEvaluationInput)
	}
}
