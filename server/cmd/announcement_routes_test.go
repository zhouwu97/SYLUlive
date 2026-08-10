package main

import (
	"reflect"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/config"
	"shenliyuan/internal/handlers"
	"shenliyuan/internal/models"
)

func newAnnouncementRouteTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.Announcement{}, &models.AnnouncementRead{}); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

// TestAnnouncementRouteAliasesConsistent 验证 /api/announcements 与
// /api/notices 两条前缀的每个 method+path 都指向同一 handler 函数。
// 别名路由一旦漂移，客户端 fallback 就会暴露不一致行为。
func TestAnnouncementRouteAliasesConsistent(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newAnnouncementRouteTestDB(t)
	handler := handlers.NewAnnouncementHandler(db)
	cfg := &config.Config{JWTSecret: "test-secret"}

	router := gin.New()
	registerAnnouncementRoutes(router, handler, db, cfg)

	byAlias := map[string][]gin.RouteInfo{}
	for _, route := range router.Routes() {
		path := route.Path
		switch {
		case path == "/api/announcements" || len(path) > len("/api/announcements") &&
			path[:len("/api/announcements")] == "/api/announcements/":
			byAlias["announcements"] = append(byAlias["announcements"], route)
		case path == "/api/notices" || len(path) > len("/api/notices") &&
			path[:len("/api/notices")] == "/api/notices/":
			byAlias["notices"] = append(byAlias["notices"], route)
		}
	}

	if len(byAlias["announcements"]) != len(byAlias["notices"]) {
		t.Fatalf("route count mismatch: announcements=%d notices=%d",
			len(byAlias["announcements"]), len(byAlias["notices"]))
	}
	if len(byAlias["announcements"]) == 0 {
		t.Fatal("no announcement routes registered")
	}

	notices := map[string]gin.RouteInfo{}
	for _, route := range byAlias["notices"] {
		key := route.Method + " " + "/api/notices" + route.Path[len("/api/notices"):]
		notices[key] = route
	}

	for _, route := range byAlias["announcements"] {
		// 把 announcements 前缀映射到 notices 命名空间后比对 handler。
		key := route.Method + " " + "/api/notices" +
			route.Path[len("/api/announcements"):]
		alias, ok := notices[key]
		if !ok {
			t.Errorf("alias route missing: %s", key)
			continue
		}
		primaryPtr := reflect.ValueOf(route.Handler).Pointer()
		aliasPtr := reflect.ValueOf(alias.Handler).Pointer()
		if primaryPtr != aliasPtr {
			t.Errorf("route %s: announcements handler %x != notices handler %x",
				key, primaryPtr, aliasPtr)
		}
	}
}
