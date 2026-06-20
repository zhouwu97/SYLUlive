package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestTokenFromRequestPrefersAuthorizationHeader(t *testing.T) {
	gin.SetMode(gin.TestMode)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Authorization", "Bearer header-token")
	req.AddCookie(&http.Cookie{Name: "jwt", Value: "cookie-token"})

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = req

	if got := tokenFromRequest(c); got != "header-token" {
		t.Fatalf("tokenFromRequest() = %q, want header-token", got)
	}
}

func TestTokenFromRequestFallsBackToCookie(t *testing.T) {
	gin.SetMode(gin.TestMode)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.AddCookie(&http.Cookie{Name: "jwt", Value: "cookie-token"})

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = req

	if got := tokenFromRequest(c); got != "cookie-token" {
		t.Fatalf("tokenFromRequest() = %q, want cookie-token", got)
	}
}

func TestTokenVersionCacheUsesTTL(t *testing.T) {
	clearTokenVersionCacheForTest()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}); err != nil {
		t.Fatalf("migrate user: %v", err)
	}
	user := models.User{
		ID:           1,
		StudentID:    "student-1",
		PasswordHash: "hash",
		TokenVersion: 1,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}

	version, err := getCachedTokenVersion(db, user.ID)
	if err != nil || version != 1 {
		t.Fatalf("first version=%d err=%v", version, err)
	}
	if err := db.Model(&models.User{}).Where("id = ?", user.ID).Update("token_version", 2).Error; err != nil {
		t.Fatalf("update token version: %v", err)
	}
	version, err = getCachedTokenVersion(db, user.ID)
	if err != nil || version != 1 {
		t.Fatalf("cached version=%d err=%v", version, err)
	}

	clearTokenVersionCacheForTest()
	version, err = getCachedTokenVersion(db, user.ID)
	if err != nil || version != 2 {
		t.Fatalf("refreshed version=%d err=%v", version, err)
	}
}
