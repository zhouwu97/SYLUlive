package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

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
		if item["credit_score"] != float64(users[0].CreditScore) {
			t.Fatalf("query=%s returned wrong credit score: %s", testCase.query, response.Body.String())
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

func TestSearchAcceptsSingleCharacterPostsAndUsers(t *testing.T) {
	db := newSearchTestDB(t)
	author := models.User{ID: 2, StudentID: "account-private", PasswordHash: "private-hash", Nickname: "好A😀"}
	if err := db.Create(&author).Error; err != nil {
		t.Fatal(err)
	}
	entry := models.Post{Title: "2 好 A 😀", Content: "单字符搜索", BoardID: models.BoardShuitie, AuthorID: author.ID, Status: models.PostStatusNormal}
	if err := db.Create(&entry).Error; err != nil {
		t.Fatal(err)
	}
	for _, kind := range []string{"posts", "users"} {
		for _, q := range []string{"2", "好", "a", "😀", " 2 "} {
			t.Run(kind+"/"+q, func(t *testing.T) {
				handler := NewSearchHandler(db, NewPostHandler(db, "", ""))
				response := performSearchRequest(t, handler.Search, "/api/search?type="+kind+"&q="+url.QueryEscape(q))
				if response.Code != http.StatusOK {
					t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
				}
				var body struct {
					Items []map[string]interface{} `json:"items"`
					Total int64                    `json:"total"`
				}
				if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
					t.Fatal(err)
				}
				if body.Total != 1 || len(body.Items) != 1 {
					t.Fatalf("unexpected results: %s", response.Body.String())
				}
				if kind == "users" {
					for _, field := range []string{"student_id", "password_hash", "email"} {
						if _, ok := body.Items[0][field]; ok {
							t.Fatalf("public search exposed %s", field)
						}
					}
				}
			})
		}
	}
}

func TestSearchSingleCharacterKeepsInputBoundsAndRateLimit(t *testing.T) {
	for _, q := range []string{"", " ", "%", "_", "*", "?", `\`, strings.Repeat("好", 65)} {
		t.Run(q, func(t *testing.T) {
			handler := NewSearchHandler(nil, nil)
			response := performSearchRequest(t, handler.Search, "/api/search?q="+url.QueryEscape(q))
			if response.Code != http.StatusBadRequest {
				t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
	db := newSearchTestDB(t)
	handler := NewSearchHandler(db, NewPostHandler(db, "", ""))
	for i := 0; i < 30; i++ {
		if !handler.allowAnonymousSearch("192.0.2.1", time.Now()) {
			t.Fatalf("request %d unexpectedly rate limited", i)
		}
	}
	response := performSearchRequest(t, handler.Search, "/api/search?q=2")
	if response.Code != http.StatusTooManyRequests || response.Header().Get("Retry-After") != "60" {
		t.Fatalf("status=%d headers=%v body=%s", response.Code, response.Header(), response.Body.String())
	}
	response = performSearchRequest(t, NewSearchHandler(db, NewPostHandler(db, "", "")).Search, "/api/search?q="+url.QueryEscape(strings.Repeat("😀", 64)))
	if response.Code != http.StatusOK {
		t.Fatalf("64 Unicode code points rejected: %d %s", response.Code, response.Body.String())
	}
}
