package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newSearchTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.File{},
		&models.Post{},
		&models.PostImage{},
		&models.Like{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

func performSearchRequest(
	t *testing.T,
	handler gin.HandlerFunc,
	path string,
) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, path, nil)
	handler(context)
	return recorder
}

func TestSearchFindsUsersByAccountAndNickname(t *testing.T) {
	db := newSearchTestDB(t)
	users := []models.User{
		{StudentID: "20260001", PasswordHash: "x", Nickname: "纯盒子"},
		{StudentID: "20260002", PasswordHash: "x", Nickname: "测试用户"},
	}
	if err := db.Create(&users).Error; err != nil {
		t.Fatalf("create users: %v", err)
	}
	handler := NewSearchHandler(db, NewPostHandler(db, "", ""))

	for _, query := range []string{"20260001", "纯盒"} {
		response := performSearchRequest(
			t,
			handler.Search,
			"/api/search?type=users&q="+query,
		)
		if response.Code != http.StatusOK {
			t.Fatalf("query=%s status=%d body=%s",
				query, response.Code, response.Body.String())
		}
		var body struct {
			Items []models.User `json:"items"`
			Total int64         `json:"total"`
		}
		if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
			t.Fatalf("decode users: %v", err)
		}
		if body.Total != 1 || len(body.Items) != 1 || body.Items[0].ID != users[0].ID {
			t.Fatalf("query=%s unexpected body=%s", query, response.Body.String())
		}
	}
}

func TestSearchFindsPostsByTitleAndContent(t *testing.T) {
	db := newSearchTestDB(t)
	user := models.User{StudentID: "20260001", PasswordHash: "x", Nickname: "作者"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	posts := []models.Post{
		{
			Title:    "高等数学复习资料",
			Content:  "期末重点",
			BoardID:  models.BoardShuitie,
			AuthorID: user.ID,
			Status:   models.PostStatusNormal,
		},
		{
			Title:    "普通标题",
			Content:  "这里包含 WeLearn 刷题方法",
			BoardID:  models.BoardShuitie,
			AuthorID: user.ID,
			Status:   models.PostStatusNormal,
		},
	}
	if err := db.Create(&posts).Error; err != nil {
		t.Fatalf("create posts: %v", err)
	}
	handler := NewSearchHandler(db, NewPostHandler(db, "", ""))

	response := performSearchRequest(
		t,
		handler.Search,
		"/api/search?type=posts&q=welearn&sort=relevance",
	)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	var body struct {
		Items []models.Post `json:"items"`
		Total int64         `json:"total"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode posts: %v", err)
	}
	if body.Total != 1 || len(body.Items) != 1 || body.Items[0].ID != posts[1].ID {
		t.Fatalf("unexpected body=%s", response.Body.String())
	}
}
