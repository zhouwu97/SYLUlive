package handlers

import (
	"encoding/json"
	"fmt"
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
	if err := db.AutoMigrate(&models.WaterTeamRecruitment{}, &models.WaterTeamApplication{},
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

func TestSearchFindsUsersByIDAndNicknameButNotAccount(t *testing.T) {
	db := newSearchTestDB(t)
	users := []models.User{
		{ID: 101, StudentID: "20260001", PasswordHash: "x", Nickname: "纯盒子"},
		{ID: 102, StudentID: "20260002", PasswordHash: "x", Nickname: "测试用户"},
	}
	if err := db.Create(&users).Error; err != nil {
		t.Fatalf("create users: %v", err)
	}
	handler := NewSearchHandler(db, NewPostHandler(db, "", ""))

	testCases := []struct {
		query      string
		wantUserID uint
		wantTotal  int64
	}{
		{query: fmt.Sprint(users[0].ID), wantUserID: users[0].ID, wantTotal: 1},
		{query: "纯盒", wantUserID: users[0].ID, wantTotal: 1},
		{query: users[0].StudentID, wantTotal: 0},
	}

	for _, testCase := range testCases {
		response := performSearchRequest(
			t,
			handler.Search,
			"/api/search?type=users&q="+testCase.query,
		)
		if response.Code != http.StatusOK {
			t.Fatalf("query=%s status=%d body=%s", testCase.query, response.Code, response.Body.String())
		}
		var body struct {
			Items []map[string]interface{} `json:"items"`
			Total int64                    `json:"total"`
		}
		if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
			t.Fatalf("decode users: %v", err)
		}
		if body.Total != testCase.wantTotal || len(body.Items) != int(testCase.wantTotal) {
			t.Fatalf("query=%s unexpected body=%s", testCase.query, response.Body.String())
		}
		if testCase.wantTotal == 0 {
			continue
		}
		item := body.Items[0]
		if item["id"] != float64(testCase.wantUserID) {
			t.Fatalf("query=%s returned wrong user: %s", testCase.query, response.Body.String())
		}
		if _, exists := item["student_id"]; exists {
			t.Fatalf("query=%s leaked student_id: %s", testCase.query, response.Body.String())
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
