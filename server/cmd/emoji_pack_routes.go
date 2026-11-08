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
	packs.GET("/:id/cover", h.ServePublicCover)
	creator := r.Group("/api/emoji/creator", middleware.AuthMiddleware(db, jwtSecret))
	creator.GET("", h.GetCreator)
	creator.POST("", middleware.RequireCommunityRules(db), h.ApplyCreator)
	mine := r.Group("/api/emoji/submissions", middleware.AuthMiddleware(db, jwtSecret))
	mine.GET("", h.ListMine)
	mine.POST("", middleware.RequireCommunityRules(db), h.Submit)
	mine.GET("/:id", h.Detail)
	mine.GET("/:id/assets/:assetId", h.ServePrivateAsset)
	mine.GET("/:id/cover", h.ServePrivateCover)
	mine.DELETE("/:id", h.Withdraw)
	admin := r.Group("/api/admin/emoji-packs", middleware.AuthMiddleware(db, jwtSecret), middleware.AdminMiddleware())
	admin.GET("", h.ListAdmin)
	admin.GET("/:id", h.Detail)
	admin.GET("/:id/assets/:assetId", h.ServePrivateAsset)
	admin.GET("/:id/cover", h.ServePrivateCover)
	admin.POST("/:id/review", h.Review)
	creators := r.Group("/api/admin/emoji-creators", middleware.AuthMiddleware(db, jwtSecret), middleware.AdminMiddleware())
	creators.GET("", h.ListCreators)
	creators.POST("/:userId/review", h.ReviewCreator)
	return service
}
