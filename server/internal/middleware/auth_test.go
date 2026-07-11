package middleware

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

func TestAuthMiddlewareErrorIncludesMachineCode(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	router := gin.New()
	router.GET("/private", AuthMiddleware(db, "secret"), func(c *gin.Context) {
		c.Status(http.StatusOK)
	})

	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/private", nil))

	if response.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d, want %d", response.Code, http.StatusUnauthorized)
	}
	var body map[string]string
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body["error"] == "" || body["code"] != "authentication_required" {
		t.Fatalf("unexpected auth error body: %#v", body)
	}
}

func TestAdminMiddlewareErrorIncludesMachineCode(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.GET("/admin", func(c *gin.Context) {
		c.Set("role", string(models.RoleUser))
	}, AdminMiddleware(), func(c *gin.Context) {
		c.Status(http.StatusOK)
	})

	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/admin", nil))

	if response.Code != http.StatusForbidden {
		t.Fatalf("status=%d, want %d", response.Code, http.StatusForbidden)
	}
	var body map[string]string
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body["error"] == "" || body["code"] != "admin_required" {
		t.Fatalf("unexpected admin error body: %#v", body)
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
