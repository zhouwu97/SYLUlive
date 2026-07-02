package services

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

func TestUpdateUserRoleAndInvalidateTokenExpiresOldJWT(t *testing.T) {
	gin.SetMode(gin.TestMode)
	middleware.InvalidateTokenVersionCache(0)

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}); err != nil {
		t.Fatalf("migrate user: %v", err)
	}

	user := models.User{
		StudentID:    "2403130233",
		PasswordHash: "hash",
		Role:         models.RoleUser,
		TokenVersion: 0,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}

	const secret = "test-secret"
	oldToken, err := middleware.GenerateToken(user.ID, string(models.RoleUser), user.TokenVersion, secret)
	if err != nil {
		t.Fatalf("generate old token: %v", err)
	}

	authRouter := gin.New()
	authRouter.GET("/protected", middleware.AuthMiddleware(db, secret), func(c *gin.Context) {
		c.Status(http.StatusNoContent)
	})

	req := httptest.NewRequest(http.MethodGet, "/protected", nil)
	req.Header.Set("Authorization", "Bearer "+oldToken)
	w := httptest.NewRecorder()
	authRouter.ServeHTTP(w, req)
	if w.Code != http.StatusNoContent {
		t.Fatalf("old token before role change status=%d body=%s", w.Code, w.Body.String())
	}

	if err := UpdateUserRoleAndInvalidateToken(db, user.ID, models.RoleAdmin); err != nil {
		t.Fatalf("update role: %v", err)
	}

	req = httptest.NewRequest(http.MethodGet, "/protected", nil)
	req.Header.Set("Authorization", "Bearer "+oldToken)
	w = httptest.NewRecorder()
	authRouter.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("old token after role change status=%d body=%s", w.Code, w.Body.String())
	}
	if got := w.Body.String(); got == "" || !strings.Contains(got, "账号状态已更新，请重新登录") {
		t.Fatalf("unexpected unauthorized message: %s", got)
	}

	var updated models.User
	if err := db.First(&updated, user.ID).Error; err != nil {
		t.Fatalf("reload user: %v", err)
	}
	newToken, err := middleware.GenerateToken(updated.ID, string(updated.Role), updated.TokenVersion, secret)
	if err != nil {
		t.Fatalf("generate new token: %v", err)
	}

	adminRouter := gin.New()
	adminRouter.GET("/admin", middleware.AuthMiddleware(db, secret), middleware.AdminMiddleware(), func(c *gin.Context) {
		c.Status(http.StatusNoContent)
	})
	req = httptest.NewRequest(http.MethodGet, "/admin", nil)
	req.Header.Set("Authorization", "Bearer "+newToken)
	w = httptest.NewRecorder()
	adminRouter.ServeHTTP(w, req)
	if w.Code != http.StatusNoContent {
		t.Fatalf("new admin token status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestUpdateUserRoleAndInvalidateTokenDowngradeExpiresAdminJWT(t *testing.T) {
	gin.SetMode(gin.TestMode)
	middleware.InvalidateTokenVersionCache(0)

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}); err != nil {
		t.Fatalf("migrate user: %v", err)
	}

	user := models.User{
		StudentID:    "2403130234",
		PasswordHash: "hash",
		Role:         models.RoleAdmin,
		TokenVersion: 0,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}

	const secret = "test-secret"
	oldAdminToken, err := middleware.GenerateToken(user.ID, string(models.RoleAdmin), user.TokenVersion, secret)
	if err != nil {
		t.Fatalf("generate old admin token: %v", err)
	}

	router := gin.New()
	router.GET("/admin", middleware.AuthMiddleware(db, secret), middleware.AdminMiddleware(), func(c *gin.Context) {
		c.Status(http.StatusNoContent)
	})

	req := httptest.NewRequest(http.MethodGet, "/admin", nil)
	req.Header.Set("Authorization", "Bearer "+oldAdminToken)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)
	if w.Code != http.StatusNoContent {
		t.Fatalf("old admin token before downgrade status=%d body=%s", w.Code, w.Body.String())
	}

	if err := UpdateUserRoleAndInvalidateToken(db, user.ID, models.RoleUser); err != nil {
		t.Fatalf("downgrade role: %v", err)
	}

	req = httptest.NewRequest(http.MethodGet, "/admin", nil)
	req.Header.Set("Authorization", "Bearer "+oldAdminToken)
	w = httptest.NewRecorder()
	router.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("old admin token after downgrade status=%d body=%s", w.Code, w.Body.String())
	}
}
