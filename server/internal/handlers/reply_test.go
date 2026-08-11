package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newReplyTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.Post{},
		&models.Reply{},
		&models.ReplyImage{},
		&models.File{},
		&models.FileUploadGrant{},
		&models.ExpLog{},
		&models.Notification{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

func createReplyTestPost(t *testing.T, db *gorm.DB) models.Post {
	t.Helper()
	createMessageTestUser(t, db, 1, "Alice")
	now := time.Now()
	post := models.Post{
		Title:          "测试帖子",
		Content:        "正文",
		BoardID:        models.BoardShuitie,
		AuthorID:       1,
		ContentKind:    models.PostContentKindNormal,
		Status:         models.PostStatusNormal,
		CreatedAt:      now,
		LastActivityAt: now,
	}
	if err := db.Create(&post).Error; err != nil {
		t.Fatalf("create post: %v", err)
	}
	return post
}

func performReplyRequest(
	t *testing.T,
	handler gin.HandlerFunc,
	postID uint,
	form url.Values,
) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(
		http.MethodPost,
		fmt.Sprintf("/api/posts/%d/replies", postID),
		strings.NewReader(form.Encode()),
	)
	context.Request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	context.Params = gin.Params{{Key: "id", Value: fmt.Sprint(postID)}}
	context.Set("user_id", uint(1))
	handler(context)
	return recorder
}

func TestReplyCreateAllowsTextWithSticker(t *testing.T) {
	db := newReplyTestDB(t)
	post := createReplyTestPost(t, db)
	handler := NewReplyHandler(db, "", "")

	const stickerID = "0cc4a3688e7b222b977fef3a078619b6"
	response := performReplyRequest(t, handler.Create, post.ID, url.Values{
		"content":    {"晚安"},
		"sticker_id": {stickerID},
	})
	if response.Code != http.StatusCreated {
		t.Fatalf("create text with sticker reply status=%d body=%s", response.Code, response.Body.String())
	}

	var reply models.Reply
	if err := json.Unmarshal(response.Body.Bytes(), &reply); err != nil {
		t.Fatalf("decode text with sticker reply: %v", err)
	}
	if reply.Content != "晚安" {
		t.Fatalf("content=%q", reply.Content)
	}
	if reply.StickerID == nil || *reply.StickerID != stickerID {
		t.Fatalf("sticker_id=%v body=%s", reply.StickerID, response.Body.String())
	}
}

func TestReplyCreateRejectsImageWithSticker(t *testing.T) {
	db := newReplyTestDB(t)
	post := createReplyTestPost(t, db)
	handler := NewReplyHandler(db, "", "")

	uploadDir := t.TempDir()
	t.Setenv("UPLOAD_DIR", uploadDir)
	if err := os.WriteFile(filepath.Join(uploadDir, "reply.png"), []byte("image"), 0o600); err != nil {
		t.Fatalf("write image: %v", err)
	}
	file := models.File{
		Hash:       "reply-image",
		Path:       "/uploads/reply.png",
		Size:       5,
		MimeType:   "image/png",
		UploaderID: 1,
		Status:     "active",
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatalf("create image file: %v", err)
	}

	const stickerID = "0cc4a3688e7b222b977fef3a078619b6"
	response := performReplyRequest(t, handler.Create, post.ID, url.Values{
		"sticker_id": {stickerID},
		"file_ids":   {fmt.Sprint(file.ID)},
	})
	if response.Code != http.StatusBadRequest {
		t.Fatalf("image with sticker status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestReplyCreateAllowsImageOnly(t *testing.T) {
	db := newReplyTestDB(t)
	post := createReplyTestPost(t, db)
	handler := NewReplyHandler(db, "", "")

	uploadDir := t.TempDir()
	t.Setenv("UPLOAD_DIR", uploadDir)
	if err := os.WriteFile(filepath.Join(uploadDir, "favorite.png"), []byte("image"), 0o600); err != nil {
		t.Fatalf("write image: %v", err)
	}
	file := models.File{
		Hash:       "favorite-image",
		Path:       "/uploads/favorite.png",
		Size:       5,
		MimeType:   "image/png",
		UploaderID: 1,
		Status:     "temporary",
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatalf("create image file: %v", err)
	}

	response := performReplyRequest(t, handler.Create, post.ID, url.Values{
		"file_ids": {fmt.Sprint(file.ID)},
	})
	if response.Code != http.StatusCreated {
		t.Fatalf("create image-only reply status=%d body=%s", response.Code, response.Body.String())
	}

	var reply models.Reply
	if err := json.Unmarshal(response.Body.Bytes(), &reply); err != nil {
		t.Fatalf("decode image-only reply: %v", err)
	}
	if reply.Content != "" || len(reply.Images) != 1 || reply.Images[0].FileID != file.ID {
		t.Fatalf("unexpected image-only reply: %s", response.Body.String())
	}
}

func TestReplyCreateUsesTextInMixedStickerNotification(t *testing.T) {
	db := newReplyTestDB(t)
	createMessageTestUser(t, db, 1, "Alice")
	createMessageTestUser(t, db, 2, "Bob")
	now := time.Now()
	post := models.Post{
		Title:          "Bob 的帖子",
		Content:        "正文",
		BoardID:        models.BoardShuitie,
		AuthorID:       2,
		ContentKind:    models.PostContentKindNormal,
		Status:         models.PostStatusNormal,
		CreatedAt:      now,
		LastActivityAt: now,
	}
	if err := db.Create(&post).Error; err != nil {
		t.Fatalf("create post: %v", err)
	}

	const stickerID = "0cc4a3688e7b222b977fef3a078619b6"
	createResponse := performReplyRequest(t, NewReplyHandler(db, "", "").Create, post.ID, url.Values{
		"content":    {"晚安"},
		"sticker_id": {stickerID},
	})
	if createResponse.Code != http.StatusCreated {
		t.Fatalf("create reply status=%d body=%s", createResponse.Code, createResponse.Body.String())
	}

	notificationResponse := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(notificationResponse)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/notifications", nil)
	context.Set("user_id", uint(2))
	NewNotificationHandler(db).GetNotifications(context)
	if notificationResponse.Code != http.StatusOK {
		t.Fatalf("get notifications status=%d body=%s", notificationResponse.Code, notificationResponse.Body.String())
	}
	var notifications []models.Notification
	if err := json.Unmarshal(notificationResponse.Body.Bytes(), &notifications); err != nil {
		t.Fatalf("decode notifications: %v", err)
	}
	if len(notifications) != 1 || notifications[0].Content != "晚安" {
		t.Fatalf("notifications=%s", notificationResponse.Body.String())
	}
}
