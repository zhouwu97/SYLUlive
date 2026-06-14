package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestPostSnapshotLoadMorePreservesOrderAndIncludesOlderPosts(t *testing.T) {
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

	var posts []models.Post
	for i := 0; i < 5; i++ {
		post := models.Post{
			Title:     fmt.Sprintf("post-%d", i+1),
			Content:   "content",
			BoardID:   models.BoardShuitie,
			AuthorID:  user.ID,
			Status:    models.PostStatusNormal,
			CreatedAt: time.Now().Add(-time.Duration(i) * time.Hour),
		}
		if err := db.Create(&post).Error; err != nil {
			t.Fatalf("create post: %v", err)
		}
		posts = append(posts, post)
	}

	sessionID := "snapshot-test"
	ActiveSnapshots.Store(sessionID, Snapshot{
		PostIDs:   []uint{posts[4].ID, posts[2].ID, posts[0].ID, posts[3].ID, posts[1].ID},
		ExpiredAt: time.Now().Add(time.Minute),
	})
	defer ActiveSnapshots.Delete(sessionID)

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(
		http.MethodGet,
		"/api/posts?scene=loadmore&session_id="+sessionID+"&offset=2&limit=2",
		nil,
	)

	NewPostHandler(db).GetList(context)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var body struct {
		Posts []models.Post `json:"posts"`
		Total int           `json:"total"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.Total != 5 ||
		len(body.Posts) != 2 ||
		body.Posts[0].ID != posts[0].ID ||
		body.Posts[1].ID != posts[3].ID {
		t.Fatalf("unexpected snapshot page: %s", recorder.Body.String())
	}
}
