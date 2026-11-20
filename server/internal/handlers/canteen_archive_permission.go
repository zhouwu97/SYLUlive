package handlers

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func respondCanteenArchivePermission(c *gin.Context, err error) bool {
	if !errors.Is(err, services.ErrCanteenArchiveSuperAdminRequired) {
		return false
	}
	c.JSON(http.StatusForbidden, gin.H{"code": "canteen_archive_super_admin_required", "error": "怀旧食堂仅超级管理员可以修改"})
	return true
}

func requireDishArchiveWrite(tx *gorm.DB, dishID, actorID uint) error {
	var dish models.CanteenDish
	if err := tx.Select("canteen_id").First(&dish, dishID).Error; err != nil {
		return err
	}
	return services.RequireCanteenArchiveWrite(tx, dish.CanteenID, actorID)
}

func requirePhotoArchiveWrite(tx *gorm.DB, photoID, actorID uint) error {
	var photo models.CanteenDishPhoto
	if err := tx.Select("dish_id").First(&photo, photoID).Error; err != nil {
		return err
	}
	return requireDishArchiveWrite(tx, photo.DishID, actorID)
}
