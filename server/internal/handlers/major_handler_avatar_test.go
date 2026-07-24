package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestMajorDetailIncludesRatingAuthorAvatar(t *testing.T) {
	gin.SetMode(gin.TestMode)

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.Major{}, &models.MajorRating{}); err != nil {
		t.Fatalf("migrate tables: %v", err)
	}

	user := models.User{
		StudentID:    "major-rating-user",
		PasswordHash: "hash",
		Nickname:     "评价用户",
		Avatar:       "/uploads/avatars/major-rating-user.png",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	major := models.Major{Name: "测试专业", Level: "本科", Verified: true}
	if err := db.Create(&major).Error; err != nil {
		t.Fatalf("create major: %v", err)
	}
	rating := models.MajorRating{
		MajorID: major.ID,
		UserID:  user.ID,
		Star:    5,
		Comment: "课程设置合理",
		Status:  "normal",
	}
	if err := db.Create(&rating).Error; err != nil {
		t.Fatalf("create rating: %v", err)
	}

	handler := NewMajorHandler(db)
	router := gin.New()
	router.GET("/majors/:id", func(c *gin.Context) {
		c.Set("user_id", user.ID)
		handler.GetDetail(c)
	})

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/majors/1", nil)
	router.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}

	var response struct {
		Ratings []struct {
			MajorID    uint   `json:"major_id"`
			UserID     uint   `json:"user_id"`
			UserName   string `json:"user_name"`
			UserAvatar string `json:"user_avatar"`
		} `json:"ratings"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(response.Ratings) != 1 {
		t.Fatalf("rating count = %d", len(response.Ratings))
	}

	actual := response.Ratings[0]
	if actual.MajorID != major.ID || actual.UserID != user.ID {
		t.Fatalf("unexpected rating identity: %+v", actual)
	}
	if actual.UserName != user.Nickname || actual.UserAvatar != user.Avatar {
		t.Fatalf("unexpected author profile: %+v", actual)
	}
}
