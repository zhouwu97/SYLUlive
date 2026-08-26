package handlers

import (
	"errors"
	"fmt"
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
// POST /api/canteens/:id/dish-submissions
func (h *CanteenDishPhotoHandler) SubmitDishPhotoV2(c *gin.Context) {
	canteenIDStr := c.Param("id")
	if canteenIDStr == "" {
		canteenIDStr = c.Param("canteenId")
	}
	canteenID, err := strconv.ParseUint(canteenIDStr, 10, 64)
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
	if muted, err := services.IsCanteenMuted(h.db, uid); err == nil && muted {
		c.JSON(http.StatusForbidden, gin.H{"code": "canteen_submission_muted", "error": "因已确认的食堂内容违规，暂时不能提交食堂评价或菜品投稿"})
		return
	}
	var canteen models.Canteen
	if err := h.db.Where("id = ? AND verified = ?", canteenID, true).First(&canteen).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}
	canteen.NormalizeOperatingStatus()
	if canteen.IsOffline {
		c.JSON(http.StatusConflict, gin.H{"code": "canteen_offline", "error": "该店当前已下架，暂不能新增菜品或实拍"})
		return
	}

	var photo models.CanteenDishPhoto
	photoReused := false
	photoMessage := "已提交审核"
	err = h.db.Transaction(func(tx *gorm.DB) error {
		if _, err := lockActiveCanteen(tx, uint(canteenID)); err != nil {
			return err
		}
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
				if dish.Status == models.DishStatusHidden {
					return errDishNameHiddenConflict
				}
				if dish.Status == models.DishStatusRejected || dish.Status == models.DishStatusArchived {
					if err := tx.Model(&dish).Updates(map[string]interface{}{
						"status": models.DishStatusPending, "reject_reason": "", "reviewed_by": nil, "reviewed_at": nil,
					}).Error; err != nil {
						return err
					}
				}
			}
		}
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&dish, dish.ID).Error; err != nil {
			return err
		}
		// file_id 是上传接口的幂等锚点：网络超时或用户重复点击时，
		// 同一张图片不能再次创建一条实拍记录，也不能被图库容量误判为新图。
		var existingPhoto models.CanteenDishPhoto
		duplicateErr := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("dish_id = ? AND file_id = ?", dish.ID, input.FileID).First(&existingPhoto).Error
		if duplicateErr == nil {
			if _, err := services.ValidateImageFileIDs(tx, []uint{input.FileID}, 1, uid); err != nil {
				return err
			}
			switch existingPhoto.Status {
			case models.DishPhotoStatusPending:
				photo = existingPhoto
				photoReused = true
				photoMessage = "这张实拍已在审核中"
				return nil
			case models.DishPhotoStatusApproved:
				photo = existingPhoto
				photoReused = true
				photoMessage = "这张实拍已在图库中"
				return nil
			case models.DishPhotoStatusRejected, models.DishPhotoStatusArchived:
				if existingPhoto.UserID != uid {
					return errDishPhotoResubmitForbidden
				}
				var userPendingCount int64
				if err := tx.Model(&models.CanteenDishPhoto{}).
					Where("dish_id = ? AND user_id = ? AND status = ?", dish.ID, uid, models.DishPhotoStatusPending).
					Count(&userPendingCount).Error; err != nil {
					return err
				}
				if userPendingCount >= 3 {
					return errDishPendingLimit
				}
				if err := tx.Model(&existingPhoto).Updates(map[string]interface{}{
					"status": models.DishPhotoStatusPending, "reject_reason": "", "reviewed_by": nil, "reviewed_at": nil,
				}).Error; err != nil {
					return err
				}
				photo = existingPhoto
				photo.Status = models.DishPhotoStatusPending
				photo.RejectReason = ""
				photo.ReviewedBy = nil
				photo.ReviewedAt = nil
				photoReused = true
				photoMessage = "已重新提交审核"
				return nil
			default:
				return fmt.Errorf("unsupported dish photo status: %s", existingPhoto.Status)
			}
		}
		if !errors.Is(duplicateErr, gorm.ErrRecordNotFound) {
			return duplicateErr
		}
		var galleryCount int64
		// 新版评价/投稿链路只按 approved 计算公共图库容量；旧 /dish-photos
		// 路径保留严格兼容语义，避免旧客户端在迁移期间无限累积 pending。
		galleryStatuses := []string{models.DishPhotoStatusApproved}
		if legacy, exists := c.Get("legacy_dish_photo_submission"); exists && legacy == true {
			galleryStatuses = []string{models.DishPhotoStatusApproved, models.DishPhotoStatusPending}
		}
		if err := tx.Model(&models.CanteenDishPhoto{}).Where("dish_id = ? AND status IN ?", dish.ID, galleryStatuses).Count(&galleryCount).Error; err != nil {
			return err
		}
		if galleryCount >= 3 {
			return errDishGalleryFull
		}
		var userPendingCount int64
		if err := tx.Model(&models.CanteenDishPhoto{}).
			Where("dish_id = ? AND user_id = ? AND status = ?", dish.ID, uid, models.DishPhotoStatusPending).
			Count(&userPendingCount).Error; err != nil {
			return err
		}
		if userPendingCount >= 3 {
			return errDishPendingLimit
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
		case errors.Is(err, errDishPendingLimit):
			c.JSON(http.StatusConflict, gin.H{"code": "dish_pending_limit", "error": "你对该菜品的待审核实拍已达到上限"})
		case errors.Is(err, errDishPhotoResubmitForbidden):
			c.JSON(http.StatusConflict, gin.H{"code": "dish_photo_resubmit_forbidden", "error": "这张实拍已由其他用户提交，不能重复认领"})
		case errors.Is(err, errDishNameHiddenConflict):
			c.JSON(http.StatusConflict, gin.H{"code": "dish_name_hidden_conflict", "error": "同名菜品曾被下架，请联系管理员恢复或合并后再投稿"})
		case errors.Is(err, errCanteenOffline):
			c.JSON(http.StatusConflict, gin.H{"code": "canteen_offline", "error": "该店当前已下架，暂不能新增菜品或实拍"})
		case errors.Is(err, services.ErrInvalidImageFileReference):
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "提交菜品审核失败"})
		}
		return
	}
	statusCode := http.StatusCreated
	if photoReused {
		statusCode = http.StatusOK
	}
	c.JSON(statusCode, gin.H{
		"message": photoMessage,
		"reused":  photoReused,
		"photo":   gin.H{"id": photo.ID, "dish_id": photo.DishID, "status": photo.Status, "file_id": photo.FileID, "created_at": photo.CreatedAt},
	})
}

// ResubmitDish 由用户明确触发被驳回/归档菜品的重新审核。
// 普通评价编辑不会调用此接口，因此管理员的驳回结论不会被静默推翻。
// POST /api/canteens/dishes/:dishId/resubmit
func (h *CanteenHandler) ResubmitDish(c *gin.Context) {
	dishID, err := strconv.ParseUint(c.Param("dishId"), 10, 64)
	if err != nil || dishID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效菜品ID"})
		return
	}
	userID, ok := requireVerifiedStudent(c, h.db, "重新提交菜品")
	if !ok {
		return
	}
	if muted, err := services.IsCanteenMuted(h.db, userID); err == nil && muted {
		c.JSON(http.StatusForbidden, gin.H{"code": "canteen_submission_muted", "error": "因已确认的食堂内容违规，暂时不能提交食堂评价或菜品投稿"})
		return
	}

	var dish models.CanteenDish
	wasResubmitted := false
	err = h.db.Transaction(func(tx *gorm.DB) error {
		// 先读出食堂 ID，再按写入链路统一锁定食堂和菜品，避免与评价提交并发穿透。
		if err := tx.First(&dish, uint(dishID)).Error; err != nil {
			return err
		}
		if _, err := lockActiveCanteen(tx, dish.CanteenID); err != nil {
			return err
		}
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&dish, uint(dishID)).Error; err != nil {
			return err
		}
		if dish.Status == models.DishStatusActive || dish.Status == models.DishStatusPending {
			return nil
		}
		if dish.Status == models.DishStatusHidden || dish.Status == models.DishStatusMerged {
			return errDishResubmitConflict
		}
		if dish.Status != models.DishStatusRejected && dish.Status != models.DishStatusArchived {
			return errDishResubmitConflict
		}

		allowed := dish.CreatedBy == userID
		if !allowed && tx.Migrator().HasTable(&models.CanteenReviewEventDish{}) {
			var relationCount int64
			if err := tx.Table("canteen_review_event_dishes AS relation").
				Joins("JOIN canteen_review_events AS review ON review.id = relation.review_event_id").
				Where("relation.dish_id = ? AND review.user_id = ? AND review.status = ?", dish.ID, userID, models.ReviewEventStatusActive).
				Count(&relationCount).Error; err != nil {
				return err
			}
			allowed = relationCount > 0
		}
		if !allowed {
			return errDishResubmitForbidden
		}

		if err := tx.Model(&dish).Updates(map[string]interface{}{
			"status": models.DishStatusPending, "reject_reason": "", "reviewed_by": nil, "reviewed_at": nil,
		}).Error; err != nil {
			return err
		}
		wasResubmitted = true
		dish.Status = models.DishStatusPending
		dish.RejectReason = ""
		return nil
	})
	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "菜品不存在"})
		case errors.Is(err, errCanteenOffline):
			c.JSON(http.StatusConflict, gin.H{"code": "canteen_offline", "error": "该店当前已下架，暂不能重新提交菜品"})
		case errors.Is(err, errDishResubmitForbidden):
			c.JSON(http.StatusForbidden, gin.H{"code": "dish_resubmit_forbidden", "error": "只能重新提交自己贡献过的菜品"})
		case errors.Is(err, errDishResubmitConflict):
			c.JSON(http.StatusConflict, gin.H{"code": "dish_resubmit_conflict", "error": "该菜品当前状态不支持重新提交"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "重新提交菜品失败"})
		}
		return
	}
	canteenDiscoveryCache.Invalidate()
	message := "菜品已重新提交审核"
	if wasResubmitted {
		message = "菜品已重新提交审核"
	} else if dish.Status == models.DishStatusActive {
		message = "菜品已经通过审核"
	} else if dish.Status == models.DishStatusPending {
		// 对原本已经 pending 的重复点击也返回明确成功语义。
		message = "菜品已在审核中"
	}
	c.JSON(http.StatusOK, gin.H{"message": message, "dish_id": dish.ID, "status": dish.Status})
}

var errDishNameHiddenConflict = errors.New("dish name conflicts with hidden dish")

var errDishPendingLimit = errors.New("dish pending limit reached")

var errDishResubmitForbidden = errors.New("dish resubmit forbidden")

var errDishResubmitConflict = errors.New("dish resubmit conflict")

var errDishPhotoResubmitForbidden = errors.New("dish photo resubmit forbidden")
