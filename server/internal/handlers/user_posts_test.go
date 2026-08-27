package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestGetUserMarketPostsIncludesMarketTagsAndImagesForEditEntry(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:user_market_posts?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.WaterTeamRecruitment{}, &models.WaterTeamApplication{},
		&models.User{},
		&models.File{},
		&models.ImageVariant{},
		&models.Post{},
		&models.PostImage{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}

	user := models.User{
		StudentID:    "20260005",
		PasswordHash: "x",
		Nickname:     "卖家",
		EduBound:     true,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	file := models.File{
		Hash:     "hash-1",
		Path:     "/uploads/market.jpg",
		Size:     123,
		MimeType: "image/jpeg",
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatalf("create file: %v", err)
	}
	post := models.Post{
		Title:      "显示器",
		Content:    "成色很好",
		BoardID:    models.BoardMarket,
		AuthorID:   user.ID,
		PostType:   "sell",
		Price:      99,
		Contact:    "站内私信",
		MarketTags: "自提,可小刀",
		Status:     models.PostStatusNormal,
	}
	if err := db.Create(&post).Error; err != nil {
		t.Fatalf("create post: %v", err)
	}
	if err := db.Create(&models.PostImage{
		PostID:    post.ID,
		FileID:    file.ID,
		SortOrder: 0,
	}).Error; err != nil {
		t.Fatalf("create post image: %v", err)
	}

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/user/1/market-posts", nil)
	context.Params = gin.Params{{Key: "id", Value: "1"}}

	NewUserHandler(db).GetUserMarketPosts(context)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}

	var body map[string]json.RawMessage
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	var posts []models.Post
	if err := json.Unmarshal(body["items"], &posts); err != nil {
		t.Fatalf("decode items: %v", err)
	}
	if len(posts) != 1 {
		t.Fatalf("posts length=%d, want 1; body=%s", len(posts), recorder.Body.String())
	}
	if posts[0].MarketTags != "自提,可小刀" {
		t.Fatalf("market tags=%q, want 自提,可小刀", posts[0].MarketTags)
	}
	if len(posts[0].Images) != 1 {
		t.Fatalf("images length=%d, want 1; body=%s", len(posts[0].Images), recorder.Body.String())
	}
	if posts[0].Images[0].File.Path != "/uploads/market.jpg" {
		t.Fatalf("image file path=%q, want /uploads/market.jpg", posts[0].Images[0].File.Path)
	}
	if strings.Contains(recorder.Body.String(), user.StudentID) {
		t.Fatalf("公开帖子响应泄露作者学号: %s", recorder.Body.String())
	}
}
