package main

import (
	"context"
	"log"
	"shenliyuan/internal/handlers"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

func registerThemePackRoutes(r *gin.Engine, db *gorm.DB, uploadDir, jwtSecret string) *services.ThemePackService {
	service := services.NewThemePackService(db, uploadDir)
	if err := service.CleanupOrphans(context.Background()); err != nil {
		log.Printf("theme pack orphan cleanup unavailable: %v", err)
	}
	h := handlers.NewThemePackHandler(service)

	// 注意：静态子路由 /submissions 必须注册在 /:familyId 参数路由之前，或确保路径无冲突。
	// Gin 中 /api/themes/submissions 与 /api/themes/:familyId 同级时，如果子段有 /submissions/:id/package，
	// 需避免同一前缀下静态名与通配符名不一致。下面统一按明确分组注册。
	themes := r.Group("/api/themes")
	themes.GET("", h.ListCatalog)

	submissions := r.Group("/api/themes/submissions", middleware.AuthMiddleware(db, jwtSecret))
	submissions.GET("", h.ListMine)
	submissions.POST("", middleware.RequireCommunityRules(db), h.Submit)
	submissions.GET("/:id/package", h.ServePrivatePackage)
	submissions.GET("/:id/preview/:mode", h.ServePrivatePreview)
	submissions.POST("/:id/withdraw", h.Withdraw)

	themes.GET("/:familyId", h.GetDetail)
	themes.GET("/:familyId/versions/:version/package", h.ServePublicPackage)
	themes.HEAD("/:familyId/versions/:version/package", h.ServePublicPackage)
	themes.GET("/:familyId/versions/:version/preview/:mode", h.ServePublicPreview)
	themes.HEAD("/:familyId/versions/:version/preview/:mode", h.ServePublicPreview)

	r.GET("/api/users/:id/themes", h.ListUserThemes)

	admin := r.Group("/api/admin/themes", middleware.AuthMiddleware(db, jwtSecret), middleware.AdminMiddleware())
	admin.GET("", h.AdminList)
	admin.POST("/:id/review", h.AdminReview)
	// Gin 要求同一父节点下的参数名保持一致，因此下架路径使用 /:id/remove 并在 handler 内读取该参数。
	admin.POST("/:id/remove", func(c *gin.Context) {
		c.Params = append(c.Params, gin.Param{Key: "familyId", Value: c.Param("id")})
		h.AdminRemove(c)
	})

	return service
}
