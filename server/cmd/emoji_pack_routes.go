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

func registerEmojiPackRoutes(r *gin.Engine, db *gorm.DB, uploadDir, jwtSecret string) *services.EmojiPackService {
	service := services.NewEmojiPackService(db, uploadDir)
	if err := service.CleanupOrphans(context.Background()); err != nil {
		log.Printf("emoji pack orphan cleanup unavailable: %v", err)
	}
	h := handlers.NewEmojiPackSubmissionHandler(service)
	packs := r.Group("/api/emoji/packs")
	packs.GET("", h.ListCatalog)
	packs.GET("/:id", h.GetCatalogPack)
	packs.GET("/:id/manifest", h.GetManifest)
	packs.GET("/:id/assets/:assetId", h.ServePublicAsset)
	mine := r.Group("/api/emoji/submissions", middleware.AuthMiddleware(db, jwtSecret))
	mine.GET("", h.ListMine)
	mine.POST("", middleware.RequireCommunityRules(db), h.Submit)
	mine.GET("/:id", h.Detail)
	mine.GET("/:id/assets/:assetId", h.ServePrivateAsset)
	mine.DELETE("/:id", h.Withdraw)
	admin := r.Group("/api/admin/emoji-packs", middleware.AuthMiddleware(db, jwtSecret), middleware.AdminMiddleware())
	admin.GET("", h.ListAdmin)
	admin.GET("/:id", h.Detail)
	admin.GET("/:id/assets/:assetId", h.ServePrivateAsset)
	admin.POST("/:id/review", h.Review)
	return service
}
