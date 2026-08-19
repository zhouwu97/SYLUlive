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
	announcements := r.Group("/api/announcements")

	{
		announcements.GET("", h.GetList)
		announcements.GET("/active", h.GetActive)
	}

	announcementsAuth := announcements.Group("")
	announcementsAuth.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{
		// 静态路由必须在 /:id 之前注册
		announcementsAuth.GET("/unread", h.GetUnread)
		announcementsAuth.GET("/unread-count", h.GetUnreadCount)
		announcementsAuth.POST("/read-all", h.MarkAllRead)
		announcementsAuth.GET("/:id", h.GetOne)
		announcementsAuth.POST("/:id/read", h.MarkRead)
	}

	announcementsAdmin := announcements.Group("")
	announcementsAdmin.Use(
		middleware.AuthMiddleware(db, cfg.JWTSecret),
		middleware.AdminMiddleware(),
	)

	{
		announcementsAdmin.GET("/admin/list", h.GetAdminList)
		announcementsAdmin.POST("", h.Create)
		announcementsAdmin.PUT("/:id", h.Update)
		announcementsAdmin.DELETE("/:id", h.Delete)
	}

	notices := r.Group("/api/notices")

	{
		notices.GET("", h.GetList)
		notices.GET("/active", h.GetActive)
	}

	noticesAuth := notices.Group("")
	noticesAuth.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{
		noticesAuth.GET("/unread", h.GetUnread)
		noticesAuth.GET("/unread-count", h.GetUnreadCount)
		noticesAuth.POST("/read-all", h.MarkAllRead)
		noticesAuth.GET("/:id", h.GetOne)
		noticesAuth.POST("/:id/read", h.MarkRead)
	}

	noticesAdmin := notices.Group("")
	noticesAdmin.Use(
		middleware.AuthMiddleware(db, cfg.JWTSecret),
		middleware.AdminMiddleware(),
	)

	{
		noticesAdmin.GET("/admin/list", h.GetAdminList)
		noticesAdmin.POST("", h.Create)
		noticesAdmin.PUT("/:id", h.Update)
		noticesAdmin.DELETE("/:id", h.Delete)
	}
}
