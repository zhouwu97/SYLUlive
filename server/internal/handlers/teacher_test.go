package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestTeacherDetailIncludesRatingAuthorIdentity(t *testing.T) {
	gin.SetMode(gin.TestMode)

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.Teacher{}, &models.TeacherRating{}, &models.Report{}); err != nil {
		t.Fatalf("migrate tables: %v", err)
	}

	user := models.User{
		StudentID:    "teacher-rating-user",
		PasswordHash: "hash",
		Nickname:     "Rating user",
		Avatar:       "/uploads/avatars/rating-user.png",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	teacher := models.Teacher{Name: "Test teacher", Course: "Test course", Verified: true}
	if err := db.Create(&teacher).Error; err != nil {
		t.Fatalf("create teacher: %v", err)
	}
	rating := models.TeacherRating{
		TeacherID: teacher.ID,
		UserID:    user.ID,
		Star:      5,
		Comment:   "Clear explanation",
		Status:    "normal",
	}
	if err := db.Create(&rating).Error; err != nil {
		t.Fatalf("create rating: %v", err)
	}

	handler := NewTeacherHandler(db)
	router := gin.New()
	router.GET("/teachers/:id", func(c *gin.Context) {
		c.Set("user_id", user.ID)
		handler.GetDetail(c)
	})

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/teachers/1", nil)
	router.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}

	var response struct {
		Ratings []struct {
			TeacherID  uint   `json:"teacher_id"`
			UserID     uint   `json:"user_id"`
			UserName   string `json:"user_name"`
			UserAvatar string `json:"user_avatar"`
			IsOwn      bool   `json:"is_own"`
		} `json:"ratings"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(response.Ratings) != 1 {
		t.Fatalf("rating count = %d", len(response.Ratings))
	}

	actual := response.Ratings[0]
	if actual.TeacherID != teacher.ID || actual.UserID != user.ID {
		t.Fatalf("unexpected rating identity: %+v", actual)
	}
	if actual.UserName != user.Nickname || actual.UserAvatar != user.Avatar {
		t.Fatalf("unexpected author profile: %+v", actual)
	}
	if !actual.IsOwn {
		t.Fatal("current user's rating should be marked as own")
	}
}

func TestTeacherRatingReportPersistsEscapedSnapshotAndRejectsDuplicate(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.Teacher{}, &models.TeacherRating{}, &models.Report{}); err != nil {
		t.Fatalf("migrate tables: %v", err)
	}
	reporter := models.User{StudentID: "reporter", PasswordHash: "hash", Nickname: "Reporter"}
	owner := models.User{StudentID: "rating-owner", PasswordHash: "hash", Nickname: "Owner"}
	if err := db.Create(&reporter).Error; err != nil {
		t.Fatalf("create reporter: %v", err)
	}
	if err := db.Create(&owner).Error; err != nil {
		t.Fatalf("create owner: %v", err)
	}
	teacher := models.Teacher{Name: "Report teacher", Course: "Course", Verified: true}
	if err := db.Create(&teacher).Error; err != nil {
		t.Fatalf("create teacher: %v", err)
	}
	rating := models.TeacherRating{
		TeacherID: teacher.ID,
		UserID:    owner.ID,
		Star:      2,
		Comment:   "老师说：\"不合适\"",
		Status:    "normal",
	}
	if err := db.Create(&rating).Error; err != nil {
		t.Fatalf("create rating: %v", err)
	}

	handler := NewTeacherHandler(db)
	call := func() *httptest.ResponseRecorder {
		recorder := httptest.NewRecorder()
		context, _ := gin.CreateTestContext(recorder)
		context.Set("user_id", reporter.ID)
		context.Params = gin.Params{{Key: "id", Value: "1"}}
		context.Request = httptest.NewRequest(http.MethodPost, "/api/teachers/rating/1/report", bytes.NewBufferString(`{"reason":"存在辱骂内容"}`))
		context.Request.Header.Set("Content-Type", "application/json")
		handler.ReportRating(context)
		return recorder
	}

	first := call()
	if first.Code != http.StatusCreated {
		t.Fatalf("first report status=%d body=%s", first.Code, first.Body.String())
	}
	var report models.Report
	if err := db.Where("reporter_id = ? AND target_type = ? AND target_id = ?", reporter.ID, "teacher_rating", rating.ID).First(&report).Error; err != nil {
		t.Fatalf("load report: %v", err)
	}
	if !json.Valid([]byte(report.TargetSnapshot)) || !strings.Contains(report.TargetSnapshot, `老师说：\"不合适\"`) {
		t.Fatalf("snapshot is not valid escaped JSON: %s", report.TargetSnapshot)
	}
	second := call()
	if second.Code != http.StatusConflict {
		t.Fatalf("duplicate report status=%d body=%s", second.Code, second.Body.String())
	}
}

func TestLegacyTeacherRateUsesCourseEvaluationStateMachine(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open("file:"+strings.ReplaceAll(t.Name(), "/", "_")+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.CourseSubject{},
		&models.CourseEvaluationSubmission{},
		&models.Teacher{},
		&models.TeacherRating{},
	); err != nil {
		t.Fatalf("migrate tables: %v", err)
	}

	user := models.User{StudentID: "legacy-rate-user", PasswordHash: "hash", Nickname: "Legacy User"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	subject := models.CourseSubject{
		Name:           "操作系统",
		NormalizedName: models.NormalizeCourseSubjectName("操作系统"),
		Verified:       true,
	}
	if err := db.Create(&subject).Error; err != nil {
		t.Fatalf("create subject: %v", err)
	}
	teacher := models.Teacher{
		Name:            "状态机教师",
		Course:          subject.Name,
		Verified:        true,
		CourseSubjectID: &subject.ID,
		NameNormalized:  models.NormalizeTeacherName("状态机教师"),
	}
	if err := db.Create(&teacher).Error; err != nil {
		t.Fatalf("create teacher: %v", err)
	}

	handler := NewTeacherHandler(db)
	router := gin.New()
	router.POST("/teachers/:id/rate", func(c *gin.Context) {
		c.Set("user_id", user.ID)
		handler.Rate(c)
	})

	post := func(star int) *httptest.ResponseRecorder {
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodPost, "/teachers/"+strconv.FormatUint(uint64(teacher.ID), 10)+"/rate",
			strings.NewReader(`{"star":`+strconv.Itoa(star)+`,"comment":"通过统一服务"}`))
		request.Header.Set("Content-Type", "application/json")
		router.ServeHTTP(recorder, request)
		return recorder
	}

	if recorder := post(4); recorder.Code != http.StatusOK {
		t.Fatalf("legacy rate create status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var submission models.CourseEvaluationSubmission
	if err := db.First(&submission).Error; err != nil {
		t.Fatalf("course evaluation submission missing: %v", err)
	}
	if submission.Status != models.CourseEvaluationStatusPublished || submission.Revision != 1 {
		t.Fatalf("unexpected first submission: %+v", submission)
	}

	if recorder := post(5); recorder.Code != http.StatusOK {
		t.Fatalf("legacy rate update status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if err := db.First(&submission, submission.ID).Error; err != nil {
		t.Fatalf("reload submission: %v", err)
	}
	if submission.Revision != 2 || submission.Star != 5 {
		t.Fatalf("legacy update must bump revision and update submission: %+v", submission)
	}
	var rating models.TeacherRating
	if err := db.Where("teacher_id = ? AND user_id = ?", teacher.ID, user.ID).First(&rating).Error; err != nil {
		t.Fatalf("rating missing: %v", err)
	}
	if rating.Star != 5 || rating.CourseEvaluationSubmissionID == nil || *rating.CourseEvaluationSubmissionID != submission.ID {
		t.Fatalf("legacy rate must use linked rating: %+v", rating)
	}
}

func TestLegacyTeacherRateRejectsUnverifiedTeacher(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open("file:"+strings.ReplaceAll(t.Name(), "/", "_")+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.Teacher{}, &models.CourseSubject{}, &models.CourseEvaluationSubmission{}, &models.TeacherRating{}); err != nil {
		t.Fatalf("migrate tables: %v", err)
	}
	user := models.User{StudentID: "unverified-rate-user", PasswordHash: "hash"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	teacher := models.Teacher{Name: "未审核教师", Course: "未审核课程", Verified: false}
	if err := db.Create(&teacher).Error; err != nil {
		t.Fatalf("create teacher: %v", err)
	}
	handler := NewTeacherHandler(db)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodPost, "/teachers/1/rate", strings.NewReader(`{"star":5}`))
	context.Request.Header.Set("Content-Type", "application/json")
	context.Params = gin.Params{{Key: "id", Value: strconv.FormatUint(uint64(teacher.ID), 10)}}
	context.Set("user_id", user.ID)
	handler.Rate(context)
	if context.Writer.Status() != http.StatusNotFound {
		t.Fatalf("unverified teacher status=%d body=%s", context.Writer.Status(), recorder.Body.String())
	}
	var count int64
	if err := db.Model(&models.TeacherRating{}).Count(&count).Error; err != nil {
		t.Fatalf("count ratings: %v", err)
	}
	if count != 0 {
		t.Fatalf("unverified teacher must not receive direct rating, count=%d", count)
	}
}
