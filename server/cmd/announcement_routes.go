package main

import (
	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/config"
	"shenliyuan/internal/handlers"
	"shenliyuan/internal/middleware"
)

// registerAnnouncementRoutes 注册公告路由。
//
// /api/announcements 与 /api/notices 是同一资源的别名：App 直连公网 IP 时
// 部分网络会卡住包含 "announcement" 的明文 HTTP 路径，客户端统一走
// /api/notices，服务端保留旧路径兼容。两套前缀必须指向同一组 handler，
// 由 announcement_routes_test.go 的 route consistency test 保证。
func registerAnnouncementRoutes(
	r *gin.Engine,
	h *handlers.AnnouncementHandler,
	db *gorm.DB,
	cfg *config.Config,
) {
	for _, prefix := range []string{"/api/announcements", "/api/notices"} {
		public := r.Group(prefix)
		public.GET("", h.GetList)
		public.GET("/active", h.GetActive)

		auth := public.Group("", middleware.AuthMiddleware(db, cfg.JWTSecret))
		// 静态路由必须在 /:id 之前注册。
		auth.GET("/unread", h.GetUnread)
		auth.GET("/unread-count", h.GetUnreadCount)
		auth.POST("/read-all", h.MarkAllRead)
		auth.GET("/:id", h.GetOne)
		auth.POST("/:id/read", h.MarkRead)

		admin := auth.Group("", middleware.AdminMiddleware())
		admin.GET("/admin/list", h.GetAdminList)
		admin.POST("", h.Create)
		admin.PUT("/:id", h.Update)
		admin.DELETE("/:id", h.Delete)
	}
}
