package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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
