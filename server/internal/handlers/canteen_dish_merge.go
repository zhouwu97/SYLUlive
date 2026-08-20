package handlers

import (
	"errors"
	"net/http"
	"strconv"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
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
		// 先迁移源菜已有 alias；同名 alias 已经指向目标/其他实体时删除重复源行，
		// 不把模糊匹配误升级成自动合并。
		var sourceAliases []models.CanteenDishAlias
		if err := tx.Where("dish_id = ?", source.ID).Find(&sourceAliases).Error; err != nil {
			return err
		}
		for _, sourceAlias := range sourceAliases {
			var conflict models.CanteenDishAlias
			err := tx.Where("canteen_id = ? AND normalized_alias = ? AND id <> ?", sourceAlias.CanteenID, sourceAlias.NormalizedAlias, sourceAlias.ID).First(&conflict).Error
			if err == nil {
				if err := tx.Delete(&sourceAlias).Error; err != nil {
					return err
				}
				continue
			}
			if !errors.Is(err, gorm.ErrRecordNotFound) {
				return err
			}
			if err := tx.Model(&sourceAlias).Update("dish_id", target.ID).Error; err != nil {
				return err
			}
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
		var archivedFileIDs []uint
		for i := range photos {
			if photos[i].Status == models.DishPhotoStatusApproved {
				if approved >= 3 {
					if err := tx.Model(&photos[i]).Updates(map[string]interface{}{"status": models.DishPhotoStatusArchived, "reviewed_by": adminID, "reviewed_at": time.Now()}).Error; err != nil {
						return err
					}
					archivedFileIDs = append(archivedFileIDs, photos[i].FileID)
				} else {
					approved++
				}
			}
			if err := tx.Model(&photos[i]).Update("dish_id", target.ID).Error; err != nil {
				return err
			}
		}
		if err := services.ReconcileFilePublicAccess(tx, archivedFileIDs...); err != nil {
			return err
		}

		// 到店评价与菜品关系表同样必须迁移；同一评价已经有目标关系时删除源重复行，
		// 避免复合唯一键冲突并确保隐藏源菜不再被引用。
		var sourceRelations []models.CanteenReviewEventDish
		if err := tx.Where("dish_id = ?", source.ID).Find(&sourceRelations).Error; err != nil {
			return err
		}
		for _, relation := range sourceRelations {
			var conflict models.CanteenReviewEventDish
			err := tx.Where("review_event_id = ? AND dish_id = ? AND id <> ?", relation.ReviewEventID, target.ID, relation.ID).First(&conflict).Error
			if err == nil {
				if err := tx.Delete(&relation).Error; err != nil {
					return err
				}
				continue
			}
			if !errors.Is(err, gorm.ErrRecordNotFound) {
				return err
			}
			if err := tx.Model(&relation).Update("dish_id", target.ID).Error; err != nil {
				return err
			}
		}

		// 旧 /rate 推荐是弱引用，也要随实体迁移；同一评价同一标准化菜名已存在目标行时，
		// 删除源重复行，保留唯一的推荐记录。
		var sourceRecommendations []models.CanteenRatingDishRecommendation
		if err := tx.Where("dish_id = ?", source.ID).Find(&sourceRecommendations).Error; err != nil {
			return err
		}
		for _, recommendation := range sourceRecommendations {
			var conflict models.CanteenRatingDishRecommendation
			err := tx.Where("rating_id = ? AND normalized_name = ? AND id <> ?", recommendation.RatingID, recommendation.NormalizedName, recommendation.ID).First(&conflict).Error
			if err == nil {
				if err := tx.Delete(&recommendation).Error; err != nil {
					return err
				}
				continue
			}
			if !errors.Is(err, gorm.ErrRecordNotFound) {
				return err
			}
			if err := tx.Model(&recommendation).Update("dish_id", target.ID).Error; err != nil {
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
