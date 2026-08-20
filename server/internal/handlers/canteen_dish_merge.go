package handlers

import (
	"errors"
	"net/http"
	"strconv"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// AdminMergeDish 将待审重复菜品合并到已有实体，并创建 alias；模糊候选不会自动触发此操作。
// POST /api/canteens/dishes/:dishId/merge {"target_dish_id": 12}
func (h *CanteenDishPhotoAdminHandler) AdminMergeDish(c *gin.Context) {
	sourceID, err := strconv.ParseUint(c.Param("dishId"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效菜品ID"})
		return
	}
	var input struct {
		TargetDishID uint `json:"target_dish_id" binding:"required"`
	}
	if err := c.ShouldBindJSON(&input); err != nil || input.TargetDishID == 0 || uint(sourceID) == input.TargetDishID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请提供不同的目标菜品"})
		return
	}
	adminID := c.GetUint("user_id")
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var source, target models.CanteenDish
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&source, sourceID).Error; err != nil {
			return err
		}
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND canteen_id = ? AND status = ?", input.TargetDishID, source.CanteenID, models.DishStatusActive).First(&target).Error; err != nil {
			return err
		}
		alias := models.CanteenDishAlias{
			CanteenID: source.CanteenID, DishID: target.ID, Alias: source.Name,
			NormalizedAlias: utils.NormalizeDishName(source.Name), CreatedBy: adminID,
		}
		if alias.NormalizedAlias != "" {
			if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&alias).Error; err != nil {
				return err
			}
		}
		var approved int64
		if err := tx.Model(&models.CanteenDishPhoto{}).Where("dish_id = ? AND status = ?", target.ID, models.DishPhotoStatusApproved).Count(&approved).Error; err != nil {
			return err
		}
		var photos []models.CanteenDishPhoto
		if err := tx.Where("dish_id = ?", source.ID).Order("created_at ASC, id ASC").Find(&photos).Error; err != nil {
			return err
		}
		for i := range photos {
			if photos[i].Status == models.DishPhotoStatusApproved {
				if approved >= 3 {
					if err := tx.Model(&photos[i]).Updates(map[string]interface{}{"status": models.DishPhotoStatusArchived, "reviewed_by": adminID, "reviewed_at": time.Now()}).Error; err != nil {
						return err
					}
					continue
				}
				approved++
			}
			if err := tx.Model(&photos[i]).Update("dish_id", target.ID).Error; err != nil {
				return err
			}
		}
		var affectedUsers []uint
		tx.Model(&models.CanteenDishReviewEvent{}).
			Where("dish_id = ?", source.ID).Distinct("user_id").Pluck("user_id", &affectedUsers)
		var sourceSummaryUsers []uint
		tx.Model(&models.CanteenDishRatingSummary{}).
			Where("dish_id = ?", source.ID).Distinct("user_id").Pluck("user_id", &sourceSummaryUsers)
		seenUsers := make(map[uint]bool, len(affectedUsers)+len(sourceSummaryUsers))
		for _, userID := range append(affectedUsers, sourceSummaryUsers...) {
			seenUsers[userID] = true
		}
		if err := tx.Model(&models.CanteenDishReviewEvent{}).Where("dish_id = ?", source.ID).Update("dish_id", target.ID).Error; err != nil {
			return err
		}
		// 先删除源摘要，再由合并后的全部事件重算，避免源/目标同一用户触发唯一键冲突。
		if err := tx.Where("dish_id = ?", source.ID).Delete(&models.CanteenDishRatingSummary{}).Error; err != nil {
			return err
		}
		for userID := range seenUsers {
			if err := recomputeDishUserSummary(tx, target.ID, userID); err != nil {
				return err
			}
		}
		if err := tx.Model(&source).Updates(map[string]interface{}{"status": models.DishStatusHidden, "updated_at": time.Now()}).Error; err != nil {
			return err
		}
		return tx.Create(&models.AdminLog{
			AdminID: adminID, AdminName: adminNickname(tx, adminID), Action: "合并菜品",
			Target: target.Name, Detail: "将菜品 " + source.Name + " 合并到 " + target.Name,
		}).Error
	})
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "菜品不存在或目标菜品无效"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "合并菜品失败"})
		return
	}
	canteenDiscoveryCache.Invalidate()
	c.JSON(http.StatusOK, gin.H{"message": "菜品已合并"})
}
