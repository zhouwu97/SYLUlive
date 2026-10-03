package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/config"
	"shenliyuan/internal/handlers"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

func newBookmarkRouteTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.PostBookmark{}); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

// TestPostBookmarkRoutesRegistered 锁定收藏路由的接线：handler 一旦存在
// 却未注册（本修复前的状态），网页端「收藏」「我的收藏」会直接 404。
func TestPostBookmarkRoutesRegistered(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newBookmarkRouteTestDB(t)
	postHandler := handlers.NewPostHandler(db, "", "")
	cfg := &config.Config{JWTSecret: "test-secret"}

	router := gin.New()
	postsAuth := router.Group("/api/posts")
	postsAuth.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.RequireCommunityRules(db))
	user := router.Group("/api/user")
	user.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	registerPostBookmarkWriteRoutes(postsAuth, postHandler)
	registerPostBookmarkListRoute(user, postHandler)

	// 生产环境在收藏路由之后才注册 userOptional 的 /:id 参数路径；
	// 同层静态路径（/bookmarks）必须先注册，gin 一旦冲突会直接 panic。
	userOptional := router.Group("/api/user")
	userOptional.GET("/:id/posts", func(c *gin.Context) {})

	// gin 的 RouteInfo.Handler 是函数名字符串；方法值注册后形如
	// "...handlers.(*PostHandler).PutBookmark-fm"，按后缀锁定到具体 handler。
	want := map[string]string{
		"PUT /api/posts/:id/bookmark":    ".PutBookmark-fm",
		"DELETE /api/posts/:id/bookmark": ".DeleteBookmark-fm",
		"GET /api/user/bookmarks":        ".ListBookmarks-fm",
	}
	found := map[string]bool{}
	for _, route := range router.Routes() {
		key := route.Method + " " + route.Path
		suffix, ok := want[key]
		if !ok {
			continue
		}
		if !strings.HasSuffix(route.Handler, suffix) {
			t.Errorf("route %s registered to %q, want handler ending in %q", key, route.Handler, suffix)
			continue
		}
		found[key] = true
	}
	for key := range want {
		if !found[key] {
			t.Errorf("route %s not registered", key)
		}
	}

	// 未带凭据请求收藏路由应得到 401（路由已匹配、进入鉴权中间件），
	// 而不是 404（路由不存在）。
	for _, tc := range []struct{ method, path string }{
		{http.MethodPut, "/api/posts/1/bookmark"},
		{http.MethodDelete, "/api/posts/1/bookmark"},
		{http.MethodGet, "/api/user/bookmarks"},
	} {
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, httptest.NewRequest(tc.method, tc.path, nil))
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s %s: got status %d, want 401 (route must exist and be guarded)", tc.method, tc.path, rec.Code)
		}
	}
}
