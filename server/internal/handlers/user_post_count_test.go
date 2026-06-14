package handlers

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestGetUserPostCountOnlyCountsVisiblePosts(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.Post{}); err != nil {
		t.Fatalf("migrate posts: %v", err)
	}

	posts := []models.Post{
		{AuthorID: 7, Status: models.PostStatusNormal},
		{AuthorID: 7, Status: models.PostStatusNormal},
		{AuthorID: 7, Status: models.PostStatusDeleted},
		{AuthorID: 8, Status: models.PostStatusNormal},
	}
	if err := db.Create(&posts).Error; err != nil {
		t.Fatalf("create posts: %v", err)
	}

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/user/7/posts/count", nil)
	context.Params = gin.Params{{Key: "id", Value: "7"}}

	NewUserHandler(db).GetUserPostCount(context)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if recorder.Body.String() != `{"count":2}` {
		t.Fatalf("body=%s want count=2", recorder.Body.String())
	}
}
