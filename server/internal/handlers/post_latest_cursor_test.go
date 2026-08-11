package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestHomeLatestFeedCursorTraversesBeyondFiveHundredWithStableTieBreaker(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(
		&models.WaterTeamRecruitment{}, &models.WaterTeamApplication{},
		&models.User{}, &models.File{}, &models.Post{}, &models.PostImage{}, &models.Like{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	user := models.User{StudentID: "latest-feed-author", PasswordHash: "x", Nickname: "作者"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}

	base := time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)
	for i := 0; i < 650; i++ {
		post := models.Post{
			Title:     fmt.Sprintf("latest-%03d", i),
			Content:   "content",
			BoardID:   models.BoardShuitie,
			AuthorID:  user.ID,
			Status:    models.PostStatusNormal,
			CreatedAt: base.Add(-time.Duration(i/100) * time.Minute),
		}
		if err := db.Create(&post).Error; err != nil {
			t.Fatalf("create post %d: %v", i, err)
		}
	}

	handler := NewPostHandler(db, "", "")
	seen := make(map[uint]struct{}, 650)
	cursorToken := ""
	total := 0
	for page := 0; page < 40; page++ {
		path := "/api/posts?board=1&sort=time&feed_version=2&limit=20"
		if cursorToken != "" {
			path += "&cursor=" + url.QueryEscape(cursorToken)
		}
		recorder := httptest.NewRecorder()
		context, _ := gin.CreateTestContext(recorder)
		context.Request = httptest.NewRequest(http.MethodGet, path, nil)
		handler.GetList(context)
		if recorder.Code != http.StatusOK {
			t.Fatalf("page %d status=%d body=%s", page, recorder.Code, recorder.Body.String())
		}
		var payload struct {
			Posts           []models.Post `json:"posts"`
			Total           int           `json:"total"`
			HasMore         bool          `json:"has_more"`
			NextCursorToken string        `json:"next_cursor_token"`
		}
		if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
			t.Fatalf("decode page %d: %v", page, err)
		}
		if payload.Total != 650 {
			t.Fatalf("page %d total=%d want=650 body=%s", page, payload.Total, recorder.Body.String())
		}
		if len(payload.Posts) == 0 || len(payload.Posts) > 20 {
			t.Fatalf("page %d returned %d posts", page, len(payload.Posts))
		}
		for _, post := range payload.Posts {
			if _, exists := seen[post.ID]; exists {
				t.Fatalf("duplicate post id=%d on page %d", post.ID, page)
			}
			seen[post.ID] = struct{}{}
			total++
		}
		if !payload.HasMore {
			break
		}
		if payload.NextCursorToken == "" {
			t.Fatalf("page %d has_more without next cursor", page)
		}
		cursorToken = payload.NextCursorToken
		if page == 39 {
			t.Fatal("cursor pagination did not terminate")
		}
	}
	if total != 650 || len(seen) != 650 {
		t.Fatalf("cursor pagination returned total=%d unique=%d, want 650", total, len(seen))
	}
}
