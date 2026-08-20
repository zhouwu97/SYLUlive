package handlers

import (
	"errors"
	"net/http"
	"strconv"
	"strings"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"shenliyuan/internal/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// SubmitDishPhotoV2 提交菜品实拍候选：新菜/新图先进入 pending，不会绕过审核公开。
// 旧 SubmitDishPhoto 保留原行为，供旧客户端兼容。
// POST /api/canteens/:id/dish-submissions
func (h *CanteenDishPhotoHandler) SubmitDishPhotoV2(c *gin.Context) {
	canteenID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	var input struct {
		DishID   *uint  `json:"dish_id"`
		DishName string `json:"dish_name"`
		FileID   uint   `json:"file_id"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误"})
		return
	}
	if input.DishID == nil && strings.TrimSpace(input.DishName) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请提供 dish_id 或 dish_name"})
		return
	}
	if input.FileID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请上传菜品实拍"})
		return
	}
	if input.DishName != "" && utils.CountGraphemes(strings.TrimSpace(input.DishName)) > MaxDishNameLength {
		c.JSON(http.StatusBadRequest, gin.H{"error": "菜名不能超过40个字"})
		return
	}
	userID, exists := c.Get("user_id")
	uid, valid := userID.(uint)
	if !exists || !valid || uid == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录后投稿", "code": "authentication_required"})
		return
	}
	var user models.User
	if err := h.db.Select("id", "student_verified_at").First(&user, uid).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "登录状态无效，请重新登录", "code": "authentication_required"})
		return
	}
	if !user.IsStudentVerified() {
		c.JSON(http.StatusForbidden, gin.H{"error": "请先绑定教务账号后投稿", "code": "edu_binding_required"})
		return
	}
	var canteen models.Canteen
	if err := h.db.Where("id = ? AND verified = ?", canteenID, true).First(&canteen).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}

	var photo models.CanteenDishPhoto
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var dish models.CanteenDish
		if input.DishID != nil {
			if err := tx.Where("id = ? AND canteen_id = ?", *input.DishID, canteenID).First(&dish).Error; err != nil {
				return errDishNotFound
			}
			if dish.Status == models.DishStatusHidden {
				return errDishNotFound
			}
		} else {
			normalized := utils.NormalizeDishName(input.DishName)
			if normalized == "" {
				return errInvalidDishName
			}
			dish = models.CanteenDish{
				CanteenID: uint(canteenID), Name: strings.TrimSpace(input.DishName),
				NormalizedName: normalized, Status: models.DishStatusPending, CreatedBy: uid,
			}
			result := tx.Clauses(clause.OnConflict{
				Columns:   []clause.Column{{Name: "canteen_id"}, {Name: "normalized_name"}},
				DoNothing: true,
			}).Create(&dish)
			if result.Error != nil {
				return result.Error
			}
			if result.RowsAffected == 0 {
				if err := tx.Where("canteen_id = ? AND normalized_name = ?", canteenID, normalized).First(&dish).Error; err != nil {
					return err
				}
			}
		}
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&dish, dish.ID).Error; err != nil {
			return err
		}
		var approvedCount int64
		if err := tx.Model(&models.CanteenDishPhoto{}).Where("dish_id = ? AND status = ?", dish.ID, models.DishPhotoStatusApproved).Count(&approvedCount).Error; err != nil {
			return err
		}
		if approvedCount >= 3 {
			return errDishGalleryFull
		}
		if _, err := services.ValidateImageFileIDs(tx, []uint{input.FileID}, 1, uid); err != nil {
			return err
		}
		photo = models.CanteenDishPhoto{DishID: dish.ID, FileID: input.FileID, UserID: uid, Status: models.DishPhotoStatusPending}
		return tx.Create(&photo).Error
	})
	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound), errors.Is(err, errDishNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "菜品不存在"})
		case errors.Is(err, errInvalidDishName):
			c.JSON(http.StatusBadRequest, gin.H{"error": "菜名不能为空"})
		case errors.Is(err, errDishGalleryFull):
			c.JSON(http.StatusConflict, gin.H{"code": "dish_gallery_full", "error": "该菜品已有3张公开实拍"})
		case errors.Is(err, services.ErrInvalidImageFileReference):
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "提交菜品审核失败"})
		}
		return
	}
	c.JSON(http.StatusCreated, gin.H{
		"message": "已提交审核",
		"photo":   gin.H{"id": photo.ID, "dish_id": photo.DishID, "status": photo.Status, "file_id": photo.FileID, "created_at": photo.CreatedAt},
	})
}
