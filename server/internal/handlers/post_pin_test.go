package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newPostPinTestDB(t *testing.T) (*gorm.DB, models.User) {
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
	user := models.User{StudentID: "20260001", PasswordHash: "x", Nickname: "作者"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	return db, user
}

func performPostPinRequest(
	t *testing.T,
	handler gin.HandlerFunc,
	method string,
	path string,
	body []byte,
) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(method, path, bytes.NewReader(body))
	context.Request.Header.Set("Content-Type", "application/json")
	if marker := strings.Index(path, "/posts/"); marker >= 0 {
		id := path[marker+len("/posts/"):]
		if slash := strings.Index(id, "/"); slash >= 0 {
			id = id[:slash]
		}
		context.Params = gin.Params{{Key: "id", Value: id}}
	}
	context.Set("user_id", uint(99))
	context.Set("role", "admin")
	handler(context)
	return recorder
}

func createPinTestPost(t *testing.T, db *gorm.DB, post models.Post) models.Post {
	t.Helper()
	if post.Content == "" {
		post.Content = "content"
	}
	if post.Status == "" {
		post.Status = models.PostStatusNormal
	}
	if post.CreatedAt.IsZero() {
		post.CreatedAt = time.Now()
	}
	if err := db.Create(&post).Error; err != nil {
		t.Fatalf("create post: %v", err)
	}
	return post
}

func TestAdminPinPostPinsOnlyShuitieAndReturnsUpdatedPost(t *testing.T) {
	db, user := newPostPinTestDB(t)
	handler := NewPostHandler(db, "", "")
	waterPost := createPinTestPost(t, db, models.Post{
		Title:    "water",
		BoardID:  models.BoardShuitie,
		AuthorID: user.ID,
	})
	marketPost := createPinTestPost(t, db, models.Post{
		Title:    "market",
		BoardID:  models.BoardMarket,
		AuthorID: user.ID,
	})

	until := time.Now().Add(48 * time.Hour).UTC().Format(time.RFC3339)
	body := []byte(fmt.Sprintf(`{"pinned_until":%q,"pinned_weight":80,"reason":"测试置顶"}`, until))
	marketResponse := performPostPinRequest(
		t,
		handler.AdminPinPost,
		http.MethodPost,
		fmt.Sprintf("/api/admin/posts/%d/pin", marketPost.ID),
		body,
	)
	if marketResponse.Code != http.StatusBadRequest {
		t.Fatalf("market status=%d body=%s", marketResponse.Code, marketResponse.Body.String())
	}

	response := performPostPinRequest(
		t,
		handler.AdminPinPost,
		http.MethodPost,
		fmt.Sprintf("/api/admin/posts/%d/pin", waterPost.ID),
		body,
	)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	var updated models.Post
	if err := json.Unmarshal(response.Body.Bytes(), &updated); err != nil {
		t.Fatalf("decode post: %v", err)
	}
	if !updated.IsPinned || updated.PinnedWeight != 80 || updated.PinnedBy != 99 || updated.PinnedReason != "测试置顶" {
		t.Fatalf("unexpected pinned post: %+v", updated)
	}
}

func TestAdminPinPostLimitExcludesCurrentPost(t *testing.T) {
	db, user := newPostPinTestDB(t)
	handler := NewPostHandler(db, "", "")
	now := time.Now()
	until := now.Add(48 * time.Hour)
	var pinned []models.Post
	for i := 0; i < 3; i++ {
		pinned = append(pinned, createPinTestPost(t, db, models.Post{
			Title:       fmt.Sprintf("pinned-%d", i),
			BoardID:     models.BoardShuitie,
			AuthorID:    user.ID,
			IsPinned:    true,
			PinnedAt:    &now,
			PinnedUntil: &until,
		}))
	}

	body := []byte(fmt.Sprintf(`{"pinned_until":%q,"pinned_weight":20}`, until.UTC().Format(time.RFC3339)))
	updateResponse := performPostPinRequest(
		t,
		handler.AdminPinPost,
		http.MethodPost,
		fmt.Sprintf("/api/admin/posts/%d/pin", pinned[0].ID),
		body,
	)
	if updateResponse.Code != http.StatusOK {
		t.Fatalf("updating existing pin should pass: status=%d body=%s", updateResponse.Code, updateResponse.Body.String())
	}

	normal := createPinTestPost(t, db, models.Post{
		Title:    "normal",
		BoardID:  models.BoardShuitie,
		AuthorID: user.ID,
	})
	limitResponse := performPostPinRequest(
		t,
		handler.AdminPinPost,
		http.MethodPost,
		fmt.Sprintf("/api/admin/posts/%d/pin", normal.ID),
		body,
	)
	if limitResponse.Code != http.StatusBadRequest {
		t.Fatalf("new pin should be rejected at limit: status=%d body=%s", limitResponse.Code, limitResponse.Body.String())
	}
}

func TestAdminUnpinPostClearsPinFieldsAndReturnsPost(t *testing.T) {
	db, user := newPostPinTestDB(t)
	handler := NewPostHandler(db, "", "")
	now := time.Now()
	until := now.Add(48 * time.Hour)
	post := createPinTestPost(t, db, models.Post{
		Title:        "pinned",
		BoardID:      models.BoardShuitie,
		AuthorID:     user.ID,
		IsPinned:     true,
		PinnedAt:     &now,
		PinnedUntil:  &until,
		PinnedBy:     99,
		PinnedWeight: 80,
		PinnedReason: "测试",
	})

	response := performPostPinRequest(
		t,
		handler.AdminUnpinPost,
		http.MethodPost,
		fmt.Sprintf("/api/admin/posts/%d/unpin", post.ID),
		nil,
	)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	var updated models.Post
	if err := json.Unmarshal(response.Body.Bytes(), &updated); err != nil {
		t.Fatalf("decode post: %v", err)
	}
	if updated.IsPinned || updated.PinnedAt != nil || updated.PinnedUntil != nil ||
		updated.PinnedBy != 0 || updated.PinnedWeight != 0 || updated.PinnedReason != "" {
		t.Fatalf("pin fields were not cleared: %+v", updated)
	}
}

func TestGetListPrioritizesActivePinnedPostsForTimeSort(t *testing.T) {
	db, user := newPostPinTestDB(t)
	handler := NewPostHandler(db, "", "")
	now := time.Now()
	activeUntil := now.Add(24 * time.Hour)
	expiredUntil := now.Add(-24 * time.Hour)
	active := createPinTestPost(t, db, models.Post{
		Title:        "active pinned",
		BoardID:      models.BoardShuitie,
		AuthorID:     user.ID,
		IsPinned:     true,
		PinnedAt:     &now,
		PinnedUntil:  &activeUntil,
		PinnedWeight: 10,
		CreatedAt:    now.Add(-48 * time.Hour),
	})
	createPinTestPost(t, db, models.Post{
		Title:       "expired pinned",
		BoardID:     models.BoardShuitie,
		AuthorID:    user.ID,
		IsPinned:    true,
		PinnedAt:    &now,
		PinnedUntil: &expiredUntil,
		CreatedAt:   now,
	})
	createPinTestPost(t, db, models.Post{
		Title:     "normal",
		BoardID:   models.BoardShuitie,
		AuthorID:  user.ID,
		CreatedAt: now.Add(-time.Hour),
	})

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/posts?board=1&sort=time&page=1&limit=10", nil)
	handler.GetList(context)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var body struct {
		Posts []models.Post `json:"posts"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Posts) == 0 || body.Posts[0].ID != active.ID {
		t.Fatalf("active pinned post should be first: %s", recorder.Body.String())
	}
}

func TestSearchRelevanceStaysBeforePinnedOrder(t *testing.T) {
	db, user := newPostPinTestDB(t)
	handler := NewPostHandler(db, "", "")
	now := time.Now()
	until := now.Add(24 * time.Hour)
	relevant := createPinTestPost(t, db, models.Post{
		Title:    "target",
		Content:  "ordinary",
		BoardID:  models.BoardShuitie,
		AuthorID: user.ID,
	})
	createPinTestPost(t, db, models.Post{
		Title:        "zzz",
		Content:      "target",
		BoardID:      models.BoardShuitie,
		AuthorID:     user.ID,
		IsPinned:     true,
		PinnedAt:     &now,
		PinnedUntil:  &until,
		PinnedWeight: 100,
	})

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/posts?board=1&q=target&sort=time&page=1&limit=10", nil)
	handler.GetList(context)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var body struct {
		Posts []models.Post `json:"posts"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Posts) == 0 || body.Posts[0].ID != relevant.ID {
		t.Fatalf("search relevance should win before pinned order: %s", recorder.Body.String())
	}
}
