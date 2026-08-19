package handlers

import (
	"bytes"
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

func newEmojiSendTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.UserFollow{},
		&models.File{},
		&models.FileUploadGrant{},
		&models.UserEmojiAsset{},
		&models.UserEmojiFavorite{},
		&models.Conversation{},
		&models.Message{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

func TestMessageEmojiSendPermission(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newEmojiSendTestDB(t)

	// User 1 = Uploader (A)
	// User 2 = Favorite collector (B)
	// User 3 = Random user without favorite or grant (C)
	// Target user = 4
	for _, id := range []uint{1, 2, 3, 4} {
		if err := db.Create(&models.User{
			ID:       id,
			Nickname: fmt.Sprintf("User%d", id),
		}).Error; err != nil {
			t.Fatalf("create user: %v", err)
		}
	}

	// Make sure User 4 follows 1, 2, 3 or vice-versa so canSendMessage doesn't block stranger PM
	for _, id := range []uint{1, 2, 3} {
		if err := db.Create(&models.UserFollow{
			FollowerID:  4,
			FollowingID: id,
		}).Error; err != nil {
			t.Fatalf("create follow: %v", err)
		}
	}

	// File uploaded by User 1
	file := models.File{
		ID:          10,
		Hash:        "shared-emoji-hash-1234",
		Path:        "/uploads/emoji/shared.png",
		Size:        1024,
		MimeType:    "image/png",
		UploaderID:  1,
		Status:      "active",
		AccessScope: models.FileAccessPrivate,
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatalf("create file: %v", err)
	}

	// User 2 has a UserEmojiAsset referencing File 10
	emojiAsset := models.UserEmojiAsset{
		ID:            20,
		UserID:        2,
		FileID:        file.ID,
		ThumbnailPath: "/uploads/emoji-thumbnails/shared.png",
		MimeType:      "image/png",
	}
	if err := db.Create(&emojiAsset).Error; err != nil {
		t.Fatalf("create emoji asset: %v", err)
	}

	h := NewMessageHandler(db)
	router := gin.New()
	router.POST("/messages/users/:user_id", func(c *gin.Context) {
		uid := c.GetHeader("X-User-ID")
		var userID uint
		if uid == "1" {
			userID = 1
		} else if uid == "2" {
			userID = 2
		} else if uid == "3" {
			userID = 3
		}
		c.Set("user_id", userID)
		h.Send(c)
	})

	// Case 1: User 2 (collector with UserEmojiAsset) sends File 10 to User 4 -> 200/201 OK
	{
		fileID := file.ID
		clientMsgID := "msg-from-user2"
		body, _ := json.Marshal(SendMessageInput{
			FileID:          &fileID,
			ClientMessageID: &clientMsgID,
		})
		req := httptest.NewRequest(http.MethodPost, "/messages/users/4", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-User-ID", "2")
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)

		if w.Code != http.StatusOK && w.Code != http.StatusCreated {
			t.Fatalf("expected User 2 (with emoji asset) to send successfully (200/201), got %d: %s", w.Code, w.Body.String())
		}
	}

	// Case 2: User 3 (no asset, no grant, not uploader) sends File 10 to User 4 -> 403 Forbidden
	{
		fileID := file.ID
		clientMsgID := "msg-from-user3"
		body, _ := json.Marshal(SendMessageInput{
			FileID:          &fileID,
			ClientMessageID: &clientMsgID,
		})
		req := httptest.NewRequest(http.MethodPost, "/messages/users/4", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-User-ID", "3")
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)

		if w.Code != http.StatusForbidden {
			t.Fatalf("expected User 3 (no rights) to be forbidden (403), got %d: %s", w.Code, w.Body.String())
		}
	}

	// Case 3: User 1 (original uploader) sends File 10 to User 4 -> 200/201 OK
	{
		fileID := file.ID
		clientMsgID := "msg-from-user1"
		body, _ := json.Marshal(SendMessageInput{
			FileID:          &fileID,
			ClientMessageID: &clientMsgID,
		})
		req := httptest.NewRequest(http.MethodPost, "/messages/users/4", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-User-ID", "1")
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)

		if w.Code != http.StatusOK && w.Code != http.StatusCreated {
			t.Fatalf("expected User 1 (uploader) to send successfully (200/201), got %d: %s", w.Code, w.Body.String())
		}
	}
}
