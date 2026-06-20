package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestUpdateAvatarVersionsSameUploadURL(t *testing.T) {
	gin.SetMode(gin.TestMode)

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}); err != nil {
		t.Fatalf("migrate users: %v", err)
	}

	user := models.User{
		StudentID:    "avatar-user",
		PasswordHash: "hash",
		Nickname:     "avatar",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}

	handler := NewUserHandler(db)
	rawAvatar := "/uploads/ab/avatar.jpg"

	first := updateAvatarForTest(t, handler, user.ID, rawAvatar)
	time.Sleep(time.Millisecond)
	second := updateAvatarForTest(t, handler, user.ID, rawAvatar)

	if !strings.HasPrefix(first, rawAvatar+"?v=") {
		t.Fatalf("first avatar should include version query, got %q", first)
	}
	if !strings.HasPrefix(second, rawAvatar+"?v=") {
		t.Fatalf("second avatar should include version query, got %q", second)
	}
	if first == second {
		t.Fatalf("same uploaded avatar URL should still be stored as a new avatar version")
	}
}

func updateAvatarForTest(t *testing.T, handler *UserHandler, userID uint, avatar string) string {
	t.Helper()

	payload, err := json.Marshal(gin.H{"avatar": avatar})
	if err != nil {
		t.Fatalf("marshal avatar payload: %v", err)
	}

	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Set("user_id", userID)
	context.Request = httptest.NewRequest(http.MethodPut, "/api/user/avatar", bytes.NewReader(payload))
	context.Request.Header.Set("Content-Type", "application/json")

	handler.UpdateAvatar(context)

	if recorder.Code != http.StatusOK {
		t.Fatalf("update avatar status = %d, body = %s", recorder.Code, recorder.Body.String())
	}

	var user models.User
	if err := handler.db.First(&user, userID).Error; err != nil {
		t.Fatalf("load user: %v", err)
	}
	return user.Avatar
}
