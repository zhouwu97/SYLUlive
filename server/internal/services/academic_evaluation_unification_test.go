package services

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
)

func TestAcademicUnificationDryRunPreservesHistoryAndIsIdempotent(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	owner := createCourseEvalUser(t, db, "legacy-owner")
	subject := createCourseEvalSubject(t, db, "课程", true)
	teacher := createCourseEvalTeacher(t, db, "教师", subject.Name, subject.ID, true)
	at := time.Date(2026, 5, 30, 8, 0, 0, 0, time.UTC)
	rating := models.TeacherRating{UserID: owner.ID, TeacherID: teacher.ID, Star: 5, Comment: strings.Repeat("评", 450), Status: "moderated_hidden", HelpfulCount: 11, CreatedAt: at, UpdatedAt: at}
	require.NoError(t, db.Create(&rating).Error)
	preview, err := UnifyAcademicEvaluations(context.Background(), db, AcademicUnificationOptions{})
	require.NoError(t, err)
	require.Equal(t, 1, preview.Create)
	var count int64
	require.NoError(t, db.Model(&models.CourseEvaluationSubmission{}).Count(&count).Error)
	require.Zero(t, count)
	_, err = UnifyAcademicEvaluations(context.Background(), db, AcademicUnificationOptions{Apply: true, ExpectedPlan: preview.Fingerprint})
	require.Error(t, err)
	_, err = UnifyAcademicEvaluations(context.Background(), db, AcademicUnificationOptions{Apply: true, BackupConfirmed: true, ExpectedPlan: "stale"})
	require.Error(t, err)
	unifyAcademicFixture(t, db)
	var master models.CourseEvaluationSubmission
	require.NoError(t, db.First(&master).Error)
	require.Equal(t, rating.Comment, master.Comment)
	require.Equal(t, at, master.CreatedAt)
	require.Equal(t, at, master.UpdatedAt)
	require.Equal(t, models.CourseEvaluationSourceLegacyTeacher, master.Source)
	require.NoError(t, db.First(&rating, rating.ID).Error)
	require.Equal(t, master.ID, *rating.CourseEvaluationSubmissionID)
	require.Equal(t, at, rating.UpdatedAt)
	require.Equal(t, 11, rating.HelpfulCount)
	require.Equal(t, "moderated_hidden", rating.Status)
	view, err := NewCourseEvaluationService(db).ListAcademicContent(owner.ID, 20, "", false)
	require.NoError(t, err)
	require.Equal(t, "moderated_hidden", view.Items[0].TeacherRatingStatus)
	repeated := unifyAcademicFixture(t, db)
	require.Zero(t, repeated.Create)
	require.Equal(t, 1, repeated.AlreadyUnified)
}

func TestAcademicUnificationRepairsEitherLinkWithoutChangingTimes(t *testing.T) {
	for _, reverse := range []bool{false, true} {
		t.Run(map[bool]string{false: "forward", true: "reverse"}[reverse], func(t *testing.T) {
			db := newCourseEvaluationServiceTestDB(t)
			owner := createCourseEvalUser(t, db, "repair-owner")
			teacher := models.Teacher{Name: "教师", Course: "课程"}
			require.NoError(t, db.Create(&teacher).Error)
			at := time.Date(2026, 5, 30, 8, 0, 0, 0, time.UTC)
			master := models.CourseEvaluationSubmission{UserID: owner.ID, DedupKey: "existing", TeacherID: &teacher.ID, CourseName: teacher.Course, TeacherName: teacher.Name, Star: 5, Comment: "相同评价", Status: models.CourseEvaluationStatusPublished, CreatedAt: at, UpdatedAt: at}
			require.NoError(t, db.Create(&master).Error)
			rating := models.TeacherRating{UserID: owner.ID, TeacherID: teacher.ID, Star: 5, Comment: master.Comment}
			if reverse {
				rating.CourseEvaluationSubmissionID = &master.ID
			}
			require.NoError(t, db.Create(&rating).Error)
			if !reverse {
				require.NoError(t, db.Model(&master).UpdateColumn("teacher_rating_id", rating.ID).Error)
			}
			before := master.UpdatedAt
			result := unifyAcademicFixture(t, db)
			require.Equal(t, 1, result.Repair)
			require.NoError(t, db.First(&master, master.ID).Error)
			require.Equal(t, rating.ID, *master.TeacherRatingID)
			require.Equal(t, before, master.UpdatedAt)
			require.NoError(t, db.First(&rating, rating.ID).Error)
			require.Equal(t, master.ID, *rating.CourseEvaluationSubmissionID)
		})
	}
}

func TestAcademicUnificationConflictsAndChangedPlanNeverWritePartialData(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	owner := createCourseEvalUser(t, db, "conflict-owner")
	other := createCourseEvalUser(t, db, "conflict-other")
	teacher := models.Teacher{Name: "教师", Course: "课程"}
	require.NoError(t, db.Create(&teacher).Error)
	master := models.CourseEvaluationSubmission{UserID: other.ID, DedupKey: "foreign", CourseName: "课程", TeacherName: "教师", Star: 5, Comment: "他人", Status: models.CourseEvaluationStatusPublished}
	require.NoError(t, db.Create(&master).Error)
	rating := models.TeacherRating{UserID: owner.ID, TeacherID: teacher.ID, Star: 5, Comment: "本人", CourseEvaluationSubmissionID: &master.ID}
	require.NoError(t, db.Create(&rating).Error)
	report, err := UnifyAcademicEvaluations(context.Background(), db, AcademicUnificationOptions{})
	require.Error(t, err)
	require.Equal(t, "owner_or_teacher_mismatch", report.Conflicts[0].Reason)
	require.NoError(t, db.Model(&rating).UpdateColumn("course_evaluation_submission_id", nil).Error)
	preview, err := UnifyAcademicEvaluations(context.Background(), db, AcademicUnificationOptions{})
	require.NoError(t, err)
	require.NoError(t, db.Model(&rating).Update("comment", "预览后已修改").Error)
	_, err = UnifyAcademicEvaluations(context.Background(), db, AcademicUnificationOptions{Apply: true, BackupConfirmed: true, ExpectedPlan: preview.Fingerprint})
	require.Error(t, err)
	var count int64
	require.NoError(t, db.Model(&models.CourseEvaluationSubmission{}).Count(&count).Error)
	require.Equal(t, int64(1), count)
}

func TestAcademicUnificationWriteFailureRollsBackWholeBatch(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	teacher := models.Teacher{Name: "教师", Course: "课程"}
	require.NoError(t, db.Create(&teacher).Error)
	for _, user := range []uint{1, 2} {
		require.NoError(t, db.Create(&models.TeacherRating{TeacherID: teacher.ID, UserID: user, Star: 5}).Error)
	}
	preview, err := UnifyAcademicEvaluations(context.Background(), db, AcademicUnificationOptions{})
	require.NoError(t, err)
	require.NoError(t, db.Exec(`CREATE TRIGGER fail_second_link BEFORE UPDATE OF course_evaluation_submission_id ON teacher_ratings WHEN NEW.id = 2 BEGIN SELECT RAISE(ABORT, 'injected'); END`).Error)
	report, err := UnifyAcademicEvaluations(context.Background(), db, AcademicUnificationOptions{Apply: true, BackupConfirmed: true, ExpectedPlan: preview.Fingerprint})
	require.Error(t, err)
	require.False(t, report.Applied)
	var count int64
	require.NoError(t, db.Model(&models.CourseEvaluationSubmission{}).Count(&count).Error)
	require.Zero(t, count)
	require.NoError(t, db.Model(&models.TeacherRating{}).Where("course_evaluation_submission_id IS NOT NULL").Count(&count).Error)
	require.Zero(t, count)
}

func TestAcademicUnifiedDeleteChecksOwnershipAndDeletesOneEvaluation(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	owner := createCourseEvalUser(t, db, "delete-owner")
	other := createCourseEvalUser(t, db, "delete-other")
	subject := createCourseEvalSubject(t, db, "课程", true)
	teacher := createCourseEvalTeacher(t, db, "教师", subject.Name, subject.ID, true)
	svc := NewCourseEvaluationService(db)
	view, err := svc.RateVerifiedTeacher(owner.ID, teacher.ID, 5, "唯一评价")
	require.NoError(t, err)
	err = svc.DeleteTeacherEvaluation(other.ID, *view.TeacherRatingID)
	assertCourseEvaluationCode(t, err, CodeCourseEvaluationForbidden)
	var master models.CourseEvaluationSubmission
	require.NoError(t, db.First(&master, view.ID).Error)
	require.Equal(t, models.CourseEvaluationStatusPublished, master.Status)
	require.NoError(t, svc.DeleteTeacherEvaluation(owner.ID, *view.TeacherRatingID))
	page, err := svc.ListAcademicContent(owner.ID, 20, "", false)
	require.NoError(t, err)
	require.Zero(t, page.Total)
	var audit models.TeacherRating
	require.NoError(t, db.Unscoped().First(&audit, *view.TeacherRatingID).Error)
	require.True(t, audit.DeletedAt.Valid)
	require.Nil(t, audit.CourseEvaluationSubmissionID)
	require.Equal(t, "唯一评价", audit.Comment)
	require.NoError(t, svc.DeleteTeacherEvaluation(owner.ID, audit.ID))
	created, err := svc.RateVerifiedTeacher(owner.ID, teacher.ID, 4, "删除后重新评价")
	require.NoError(t, err)
	require.NotEqual(t, view.ID, created.ID)
}

func TestAcademicUnifiedDeleteFailureRollsBackProjectionAndMaster(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	owner := createCourseEvalUser(t, db, "delete-rollback")
	subject := createCourseEvalSubject(t, db, "课程", true)
	teacher := createCourseEvalTeacher(t, db, "教师", subject.Name, subject.ID, true)
	svc := NewCourseEvaluationService(db)
	view, err := svc.RateVerifiedTeacher(owner.ID, teacher.ID, 5, "保留")
	require.NoError(t, err)
	require.NoError(t, db.Exec(`CREATE TRIGGER fail_master_delete BEFORE DELETE ON course_evaluation_submissions BEGIN SELECT RAISE(ABORT, 'injected'); END`).Error)
	require.Error(t, svc.DeleteTeacherEvaluation(owner.ID, *view.TeacherRatingID))
	var projection models.TeacherRating
	require.NoError(t, db.First(&projection, *view.TeacherRatingID).Error)
	require.Equal(t, view.ID, *projection.CourseEvaluationSubmissionID)
	var master models.CourseEvaluationSubmission
	require.NoError(t, db.First(&master, view.ID).Error)
}

func TestAcademicUnifiedCommentLimitPreservesLegacy500Characters(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	owner := createCourseEvalUser(t, db, "comment-boundary")
	subject := createCourseEvalSubject(t, db, "课程", true)
	teacher := createCourseEvalTeacher(t, db, "教师", subject.Name, subject.ID, true)
	svc := NewCourseEvaluationService(db)
	require.Equal(t, 500, models.CourseEvaluationCommentMaxRunes)
	view, err := svc.RateVerifiedTeacher(owner.ID, teacher.ID, 5, strings.Repeat("评", 500))
	require.NoError(t, err)
	require.Equal(t, strings.Repeat("评", 500), view.Comment)
	_, err = svc.Update(owner.ID, view.ID, UpdateCourseEvaluationInput{CourseName: subject.Name, TeacherName: teacher.Name, Star: 4, Comment: strings.Repeat("评", 501), Revision: view.Revision})
	assertCourseEvaluationCode(t, err, CodeInvalidCourseEvaluationInput)
	var stored models.CourseEvaluationSubmission
	require.NoError(t, db.First(&stored, view.ID).Error)
	require.Equal(t, view.Comment, stored.Comment)
}
