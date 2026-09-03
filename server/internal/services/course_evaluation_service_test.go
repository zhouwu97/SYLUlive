package services

import (
	"errors"
	"strings"
	"testing"

	"shenliyuan/internal/models"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

// newCourseEvaluationServiceTestDB 构造课程评价服务层测试数据库。
// 覆盖状态机涉及的学科、提交、教师、评价、通知与管理员日志表。
func newCourseEvaluationServiceTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+stringsForCourseEvalDB(t.Name())+"?mode=memory&cache=shared"), &gorm.Config{TranslateError: true})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&models.User{},
		&models.CourseSubject{},
		&models.CourseSubjectAlias{},
		&models.CourseEvaluationSubmission{},
		&models.Teacher{},
		&models.TeacherRating{},
		&models.Notification{},
		&models.AdminLog{},
	))
	return db
}

func stringsForCourseEvalDB(value string) string {
	return strings.NewReplacer("/", "_", " ", "_", "-", "_").Replace(value)
}

func createCourseEvalUser(t *testing.T, db *gorm.DB, studentID string) models.User {
	t.Helper()
	user := models.User{StudentID: studentID, PasswordHash: "test-password", Nickname: studentID}
	require.NoError(t, db.Create(&user).Error)
	return user
}

func createCourseEvalSubject(t *testing.T, db *gorm.DB, name string, verified bool) models.CourseSubject {
	t.Helper()
	subject := models.CourseSubject{
		Name:           name,
		NormalizedName: models.NormalizeCourseSubjectName(name),
		Verified:       verified,
	}
	require.NoError(t, db.Create(&subject).Error)
	return subject
}

func createCourseEvalTeacher(t *testing.T, db *gorm.DB, name, course string, subjectID uint, verified bool) models.Teacher {
	t.Helper()
	teacher := models.Teacher{
		Name:            name,
		Course:          course,
		Verified:        verified,
		CourseSubjectID: &subjectID,
		NameNormalized:  models.NormalizeTeacherName(name),
	}
	require.NoError(t, db.Create(&teacher).Error)
	return teacher
}

// assertCourseEvaluationCode 断言错误为携带指定业务码的 CourseEvaluationError。
func assertCourseEvaluationCode(t *testing.T, err error, wantCode string) {
	t.Helper()
	var evalErr *CourseEvaluationError
	require.True(t, errors.As(err, &evalErr), "期望 CourseEvaluationError，实际 %v", err)
	require.Equal(t, wantCode, evalErr.Code, "业务码不符，错误=%v", err)
}

func TestCourseEvaluationSubmitPublishesWhenVerified(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	svc := NewCourseEvaluationService(db)
	user := createCourseEvalUser(t, db, "20260001")
	subject := createCourseEvalSubject(t, db, "高等数学A1", true)
	teacher := createCourseEvalTeacher(t, db, "张三", subject.Name, subject.ID, true)

	view, err := svc.Submit(user.ID, SubmitInput{
		CourseName:      subject.Name,
		CourseSubjectID: &subject.ID,
		TeacherName:     teacher.Name,
		TeacherID:       &teacher.ID,
		Star:            5,
		Comment:         "讲得很好",
	})
	require.NoError(t, err)
	require.Equal(t, models.CourseEvaluationStatusPublished, view.Status)
	require.NotNil(t, view.TeacherRatingID, "已审核学科+教师应建立教师评价关联")

	var rating models.TeacherRating
	require.NoError(t, db.First(&rating, *view.TeacherRatingID).Error)
	require.Equal(t, teacher.ID, rating.TeacherID)
	require.Equal(t, user.ID, rating.UserID)
	require.Equal(t, 5, rating.Star)
	require.NotNil(t, rating.CourseEvaluationSubmissionID)
	require.Equal(t, view.ID, *rating.CourseEvaluationSubmissionID)
}

func TestCourseEvaluationSubmitStaysPendingWhenSubjectMissing(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	svc := NewCourseEvaluationService(db)
	user := createCourseEvalUser(t, db, "20260002")

	view, err := svc.Submit(user.ID, SubmitInput{
		CourseName:  "不存在的课程",
		TeacherName: "新教师",
		Star:        4,
		Comment:     "希望能收录",
	})
	require.NoError(t, err)
	require.Equal(t, models.CourseEvaluationStatusPending, view.Status)
	require.Nil(t, view.CourseSubjectID, "缺学科时不应创建公开学科")
	require.Nil(t, view.TeacherRatingID, "缺学科时不应创建公开评价")
	require.Equal(t, "不存在的课程", view.ProposedCourseName)

	var subjectCount, teacherCount, ratingCount int64
	require.NoError(t, db.Model(&models.CourseSubject{}).Count(&subjectCount).Error)
	require.NoError(t, db.Model(&models.Teacher{}).Count(&teacherCount).Error)
	require.NoError(t, db.Model(&models.TeacherRating{}).Count(&ratingCount).Error)
	require.Zero(t, subjectCount, "审核前不应创建公开学科")
	require.Zero(t, teacherCount, "审核前不应创建公开教师")
	require.Zero(t, ratingCount, "审核前不应创建公开评价")
}

func TestCourseEvaluationNumberedSportsUsesCanonicalNameWhenSubjectMissing(t *testing.T) {
	for _, courseName := range []string{"体育1", "体育2", "体育3", "体育4", "体育5"} {
		t.Run(courseName, func(t *testing.T) {
			db := newCourseEvaluationServiceTestDB(t)
			svc := NewCourseEvaluationService(db)
			user := createCourseEvalUser(t, db, "student-"+courseName)

			resolved, err := svc.Resolve(user.ID, courseName, "体育教师")
			require.NoError(t, err)
			require.Equal(t, "体育", resolved.CourseName)
			require.True(t, resolved.RequiresConfirmation)
			require.Empty(t, resolved.CourseSubjects)

			view, err := svc.Submit(user.ID, SubmitInput{
				CourseName:  courseName,
				TeacherName: "体育教师",
				Star:        5,
				Comment:     "课程评价",
			})
			require.NoError(t, err)
			require.Equal(t, models.CourseEvaluationStatusPending, view.Status)
			require.Equal(t, "体育", view.CourseName)
			require.Equal(t, "体育", view.ProposedCourseName)
		})
	}
}

func TestCourseEvaluationSubmitRequiresConfirmationForAlias(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	svc := NewCourseEvaluationService(db)
	user := createCourseEvalUser(t, db, "20260003")
	subject := createCourseEvalSubject(t, db, "高等数学A1", true)
	require.NoError(t, db.Create(&models.CourseSubjectAlias{
		CourseSubjectID: subject.ID,
		Alias:           "高数",
		NormalizedAlias: models.NormalizeCourseSubjectName("高数"),
	}).Error)

	_, err := svc.Submit(user.ID, SubmitInput{
		CourseName:  "高数",
		TeacherName: "张三",
		Star:        5,
	})
	assertCourseEvaluationCode(t, err, CodeCourseEvaluationCandidateRequired)
}

func TestCourseEvaluationUpdateIncrementsRevision(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	svc := NewCourseEvaluationService(db)
	user := createCourseEvalUser(t, db, "20260004")

	created, err := svc.Submit(user.ID, SubmitInput{
		CourseName:  "待收录课程",
		TeacherName: "李四",
		Star:        3,
		Comment:     "第一版",
	})
	require.NoError(t, err)
	require.Equal(t, 1, created.Revision)

	updated, err := svc.Update(user.ID, created.ID, SubmitInput{
		CourseName:  "待收录课程",
		TeacherName: "李四",
		Star:        4,
		Comment:     "第二版",
		Revision:    created.Revision,
	})
	require.NoError(t, err)
	require.Equal(t, 2, updated.Revision, "pending 编辑应递增 revision")
	require.Equal(t, models.CourseEvaluationStatusPending, updated.Status)
	require.Equal(t, "第二版", updated.Comment)
}

func TestCourseEvaluationUpdateRejectsStaleRevision(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	svc := NewCourseEvaluationService(db)
	user := createCourseEvalUser(t, db, "20260005")

	created, err := svc.Submit(user.ID, SubmitInput{
		CourseName:  "待收录课程",
		TeacherName: "王五",
		Star:        3,
	})
	require.NoError(t, err)

	// 先编辑一次，revision 变为 2。
	if _, err := svc.Update(user.ID, created.ID, SubmitInput{
		CourseName:  "待收录课程",
		TeacherName: "王五",
		Star:        4,
		Revision:    created.Revision,
	}); err != nil {
		t.Fatalf("首次编辑失败: %v", err)
	}

	// 再用旧 revision 编辑应触发冲突。
	_, err = svc.Update(user.ID, created.ID, SubmitInput{
		CourseName:  "待收录课程",
		TeacherName: "王五",
		Star:        5,
		Revision:    created.Revision, // 过期的 revision=1
	})
	assertCourseEvaluationCode(t, err, CodeCourseEvaluationRevisionConflict)
}

func TestCourseEvaluationApprovePublishesAndNotifies(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	svc := NewCourseEvaluationService(db)
	user := createCourseEvalUser(t, db, "20260006")
	admin := createCourseEvalUser(t, db, "admin01")

	created, err := svc.Submit(user.ID, SubmitInput{
		CourseName:  "离散数学",
		TeacherName: "赵老师",
		Star:        5,
		Comment:     "深入浅出",
	})
	require.NoError(t, err)
	require.Equal(t, models.CourseEvaluationStatusPending, created.Status)

	view, err := svc.Approve(admin.ID, created.ID, created.Revision)
	require.NoError(t, err)
	require.Equal(t, models.CourseEvaluationStatusPublished, view.Status)
	require.NotNil(t, view.CourseSubjectID)
	require.NotNil(t, view.TeacherID)
	require.NotNil(t, view.TeacherRatingID)

	// 学科与教师应已创建并审核通过。
	var subject models.CourseSubject
	require.NoError(t, db.First(&subject, *view.CourseSubjectID).Error)
	require.True(t, subject.Verified)
	var teacher models.Teacher
	require.NoError(t, db.First(&teacher, *view.TeacherID).Error)
	require.True(t, teacher.Verified)

	// 应写入幂等通知：不关联帖子、related_id 为提交 ID。
	var notif models.Notification
	require.NoError(t, db.Where("user_id = ? AND type = ?", user.ID, models.NotificationTypeCourseEvaluationResult).
		First(&notif).Error)
	require.Equal(t, created.ID, notif.RelatedID)
	require.Zero(t, notif.PostID, "该类型通知不应关联帖子")
	require.Zero(t, notif.FromUID)
}

func TestCourseEvaluationApproveRejectsStaleRevision(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	svc := NewCourseEvaluationService(db)
	user := createCourseEvalUser(t, db, "20260007")
	admin := createCourseEvalUser(t, db, "admin02")

	created, err := svc.Submit(user.ID, SubmitInput{
		CourseName:  "待审核课程",
		TeacherName: "钱老师",
		Star:        3,
	})
	require.NoError(t, err)

	if _, err := svc.Update(user.ID, created.ID, SubmitInput{
		CourseName:  "待审核课程",
		TeacherName: "钱老师",
		Star:        4,
		Revision:    created.Revision,
	}); err != nil {
		t.Fatalf("编辑失败: %v", err)
	}

	// 管理员用旧 revision 审核应触发冲突。
	_, err = svc.Approve(admin.ID, created.ID, created.Revision)
	assertCourseEvaluationCode(t, err, CodeCourseEvaluationRevisionConflict)
}

func TestCourseEvaluationRejectRequiresReason(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	svc := NewCourseEvaluationService(db)
	user := createCourseEvalUser(t, db, "20260008")
	admin := createCourseEvalUser(t, db, "admin03")

	created, err := svc.Submit(user.ID, SubmitInput{
		CourseName:  "待审核课程",
		TeacherName: "孙老师",
		Star:        5,
	})
	require.NoError(t, err)

	_, err = svc.Reject(admin.ID, created.ID, created.Revision, "   ")
	assertCourseEvaluationCode(t, err, CodeCourseEvaluationReasonRequired)

	view, err := svc.Reject(admin.ID, created.ID, created.Revision, "评价内容与课程不符")
	require.NoError(t, err)
	require.Equal(t, models.CourseEvaluationStatusNeedsEdit, view.Status)
	require.Equal(t, "评价内容与课程不符", view.ReviewReason)
	require.Nil(t, view.TeacherRatingID, "驳回应清理临时评价关联")
}

func TestCourseEvaluationRatingUniquePerUserPerTeacher(t *testing.T) {
	db := newCourseEvaluationServiceTestDB(t)
	svc := NewCourseEvaluationService(db)
	user := createCourseEvalUser(t, db, "20260009")
	subject := createCourseEvalSubject(t, db, "线性代数", true)
	teacher := createCourseEvalTeacher(t, db, "周老师", subject.Name, subject.ID, true)

	if _, err := svc.Submit(user.ID, SubmitInput{
		CourseName:      subject.Name,
		CourseSubjectID: &subject.ID,
		TeacherName:     teacher.Name,
		TeacherID:       &teacher.ID,
		Star:            4,
		Comment:         "第一次评价",
	}); err != nil {
		t.Fatalf("首次提交失败: %v", err)
	}

	// 同一用户对同一教师再次提交，应更新同一条教师评价，而不是新增。
	if _, err := svc.Submit(user.ID, SubmitInput{
		CourseName:      subject.Name,
		CourseSubjectID: &subject.ID,
		TeacherName:     teacher.Name,
		TeacherID:       &teacher.ID,
		Star:            5,
		Comment:         "修改后的评价",
	}); err != nil {
		t.Fatalf("二次提交失败: %v", err)
	}

	var count int64
	require.NoError(t, db.Model(&models.TeacherRating{}).
		Where("teacher_id = ? AND user_id = ?", teacher.ID, user.ID).Count(&count).Error)
	require.Equal(t, int64(1), count, "一位用户对一位教师应只有一条评价")
}
