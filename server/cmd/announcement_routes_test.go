package main

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/config"
	"shenliyuan/internal/handlers"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

func newAnnouncementRouteTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}, &models.Announcement{}, &models.AnnouncementRead{}); err != nil {
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
	h := handlers.NewAnnouncementHandler(db)
	cfg := &config.Config{JWTSecret: "test-secret"}

	router := gin.New()
	registerAnnouncementRoutes(router, h, db, cfg)

	routes := map[string]uintptr{}
	for _, route := range router.Routes() {
		routes[route.Method+" "+route.Path] = reflect.ValueOf(route.HandlerFunc).Pointer()
	}
	expected := map[string]gin.HandlerFunc{
		"GET ":              h.GetList,
		"GET /active":       h.GetActive,
		"GET /unread":       h.GetUnread,
		"GET /unread-count": h.GetUnreadCount,
		"POST /read-all":    h.MarkAllRead,
		"GET /:id":          h.GetOne,
		"POST /:id/read":    h.MarkRead,
		"GET /admin/list":   h.GetAdminList,
		"POST ":             h.Create,
		"PUT /:id":          h.Update,
		"DELETE /:id":       h.Delete,
	}
	require.Len(t, routes, 2*len(expected))
	for _, prefix := range []string{"/api/announcements", "/api/notices"} {
		for route, handler := range expected {
			method, path, _ := strings.Cut(route, " ")
			key := method + " " + prefix + path
			require.Equal(t, reflect.ValueOf(handler).Pointer(), routes[key], key)
		}
	}
}

func TestAnnouncementAliasAccessAndReadState(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, prefix := range []string{"/api/announcements", "/api/notices"} {
		t.Run(prefix, func(t *testing.T) {
			db := newAnnouncementRouteTestDB(t)
			const secret = "announcement-route-test"
			router := gin.New()
			registerAnnouncementRoutes(router, handlers.NewAnnouncementHandler(db), db, &config.Config{JWTSecret: secret})

			token := func(role models.Role) string {
				user := models.User{PasswordHash: "fixture", Role: role, Nickname: string(role)}
				require.NoError(t, db.Create(&user).Error)
				middleware.InvalidateTokenVersionCache(user.ID)
				t.Cleanup(func() { middleware.InvalidateTokenVersionCache(user.ID) })
				for _, doc := range models.RequiredLegalDocuments(false) {
					require.NoError(t, db.Create(&models.UserLegalConsent{UserID: user.ID, Document: doc, Version: models.LegalDocumentVersion}).Error)
				}
				signed, err := middleware.GenerateToken(user.ID, string(role), user.TokenVersion, secret)
				require.NoError(t, err)
				return signed
			}
			user, admin := token(models.RoleUser), token(models.RoleAdmin)
			request := func(method, path, bearer, body string, status int) []byte {
				t.Helper()
				req := httptest.NewRequest(method, prefix+path, strings.NewReader(body))
				if bearer != "" {
					req.Header.Set("Authorization", "Bearer "+bearer)
				}
				if body != "" {
					req.Header.Set("Content-Type", "application/json")
				}
				rec := httptest.NewRecorder()
				router.ServeHTTP(rec, req)
				require.Equal(t, status, rec.Code, "%s %s: %s", method, path, rec.Body.String())
				return rec.Body.Bytes()
			}

			request("GET", "/active", "", "", 200)
			request("GET", "/unread", "", "", 401)
			request("GET", "/admin/list", user, "", 403)
			request("POST", "", user, "{}", 403)
			created := request("POST", "", admin, `{"title":"公告","content":"测试公告"}`, 201)
			var announcement models.Announcement
			require.NoError(t, json.Unmarshal(created, &announcement))
			require.NotZero(t, announcement.ID)
			request("GET", "/admin/list", admin, "", 200)
			var unread []models.Announcement
			require.NoError(t, json.Unmarshal(request("GET", "/unread", user, "", 200), &unread))
			require.Len(t, unread, 1)
			require.Equal(t, announcement.ID, unread[0].ID)
			request("POST", fmt.Sprintf("/%d/read", announcement.ID), user, "", 200)
			require.JSONEq(t, "[]", string(request("GET", "/unread", user, "", 200)))
		})
	}
}
