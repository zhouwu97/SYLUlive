package handlers

import (
	"errors"
	"net/http"
	"strconv"
	"strings"

	"shenliyuan/internal/config"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"shenliyuan/internal/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// errDishGalleryFull 该菜品已有 3 张审核实拍。
var errDishGalleryFull = errors.New("dish_gallery_full")

// MaxDishNameLength 菜名最大可见字符数（与客户端 maxLength: 40 对齐）。
const MaxDishNameLength = 40

// errDishPhotoAlreadyReviewed 该实拍已被审核处理。
var errDishPhotoAlreadyReviewed = errors.New("dish_photo_already_reviewed")

// CanteenDishPhotoHandler 菜品实拍投稿接口。
type CanteenDishPhotoHandler struct {
	db *gorm.DB
}

func NewCanteenDishPhotoHandler(db *gorm.DB) *CanteenDishPhotoHandler {
	return &CanteenDishPhotoHandler{db: db}
}

// SubmitDishPhoto 学生投稿菜品实拍。
// POST /api/canteens/:canteenId/dish-photos
// Body 二选一：{"dish_id": 12, "file_id": 9527} 或 {"dish_name": "锅包肉", "file_id": 9527}
func (h *CanteenDishPhotoHandler) SubmitDishPhoto(c *gin.Context) {
	if !config.IsReviewEnabled() {
		c.JSON(http.StatusServiceUnavailable, gin.H{
			"code":  "review_temporarily_disabled",
			"error": "菜品实拍投稿暂未开放",
		})
		return
	}
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
	if input.DishID != nil && strings.TrimSpace(input.DishName) != "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "dish_id 与 dish_name 只能二选一"})
		return
	}
	if input.FileID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请上传实拍图片"})
		return
	}
	// 菜名长度权威校验（1～40 个可见字符），避免极长菜名变成数据库错误。
	if input.DishName != "" && utils.CountGraphemes(strings.TrimSpace(input.DishName)) > MaxDishNameLength {
		c.JSON(http.StatusBadRequest, gin.H{"error": "菜名不能超过40个字"})
		return
	}

	// 登录校验
	userIDValue, exists := c.Get("user_id")
	userID, validUserID := userIDValue.(uint)
	if !exists || !validUserID || userID == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录后投稿", "code": "authentication_required"})
		return
	}
	var user models.User
	if err := h.db.Select("id", "student_verified_at", "edu_bound").First(&user, userID).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "登录状态无效，请重新登录", "code": "authentication_required"})
		return
	}
	if !user.IsStudentVerified() {
		c.JSON(http.StatusForbidden, gin.H{"error": "请先绑定教务账号后投稿", "code": "edu_binding_required"})
		return
	}

	// 食堂必须存在且已审核
	var canteen models.Canteen
	if err := h.db.First(&canteen, canteenID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}
	if !canteen.Verified {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}

	var photo models.CanteenDishPhoto
	err = h.db.Transaction(func(tx *gorm.DB) error {
		// 查找或创建 Dish
		var dish models.CanteenDish
		if input.DishID != nil {
			if err := tx.Where("id = ? AND canteen_id = ?", *input.DishID, canteenID).First(&dish).Error; err != nil {
				return err
			}
			if dish.Status != models.DishStatusActive {
				return errDishNotFound
			}
		} else {
			normalized := utils.NormalizeDishName(input.DishName)
			if normalized == "" {
				return errInvalidDishName
			}
			// 同名菜并发创建：INSERT ... ON CONFLICT DO NOTHING，
			// 命中唯一索引直接复用已有行，绝不在 PostgreSQL 事务内捕获
			// unique error 后继续执行（事务已进入失败状态）。
			dish = models.CanteenDish{
				CanteenID:      uint(canteenID),
				Name:           strings.TrimSpace(input.DishName),
				NormalizedName: normalized,
				Status:         models.DishStatusActive,
				CreatedBy:      userID,
			}
			result := tx.Clauses(clause.OnConflict{
				Columns: []clause.Column{
					{Name: "canteen_id"},
					{Name: "normalized_name"},
				},
				DoNothing: true,
			}).Create(&dish)
			if result.Error != nil {
				return result.Error
			}
			if result.RowsAffected == 0 {
				// 并发下被其他请求先创建 → 复用已有 active 行
				if err := tx.Where("canteen_id = ? AND normalized_name = ? AND status = ?",
					canteenID, normalized, models.DishStatusActive).First(&dish).Error; err != nil {
					return err
				}
			}
		}

		// 锁定 dish，串行化 3 图上限判断
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&dish, dish.ID).Error; err != nil {
			return err
		}

		// approved 上限检查
		var approvedCount int64
		if err := tx.Model(&models.CanteenDishPhoto{}).
			Where("dish_id = ? AND status = ?", dish.ID, models.DishPhotoStatusApproved).
			Count(&approvedCount).Error; err != nil {
			return err
		}
		if approvedCount >= 3 {
			return errDishGalleryFull
		}

		// 同一用户同一菜最多一个 pending
		var pendingCount int64
		if err := tx.Model(&models.CanteenDishPhoto{}).
			Where("dish_id = ? AND user_id = ? AND status = ?", dish.ID, userID, models.DishPhotoStatusPending).
			Count(&pendingCount).Error; err != nil {
			return err
		}
		if pendingCount > 0 {
			return errPendingPhotoExists
		}

		// 校验文件（存在/图片/磁盘/所有权）
		if _, err := services.ValidateImageFileIDs(tx, []uint{input.FileID}, 1, userID); err != nil {
			return err
		}

		// 文件认领为 active/private（审核通过前绝不公开）
		if err := services.ClaimPrivateFiles(tx, []uint{input.FileID}); err != nil {
			return err
		}

		photo = models.CanteenDishPhoto{
			DishID: dish.ID,
			FileID: input.FileID,
			UserID: userID,
			Status: models.DishPhotoStatusPending,
		}
		return tx.Create(&photo).Error
	})

	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "菜品不存在"})
		case errors.Is(err, errDishNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "菜品不存在"})
		case errors.Is(err, errInvalidDishName):
			c.JSON(http.StatusBadRequest, gin.H{"error": "菜名不能为空"})
		case errors.Is(err, errDishGalleryFull):
			c.JSON(http.StatusConflict, gin.H{"code": "dish_gallery_full", "error": "该菜品已有3张审核实拍"})
		case errors.Is(err, errPendingPhotoExists):
			c.JSON(http.StatusConflict, gin.H{"code": "pending_photo_exists", "error": "该菜品已有待审核实拍"})
		case errors.Is(err, services.ErrInvalidImageFileReference):
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		case isUniqueConstraintError(err):
			c.JSON(http.StatusConflict, gin.H{"code": "duplicate_photo", "error": "该图片已被用于其他投稿"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "提交实拍失败"})
		}
		return
	}

	c.JSON(http.StatusCreated, gin.H{
		"message": "已提交审核",
		"photo": gin.H{
			"id":       photo.ID,
			"dish_id":  photo.DishID,
			"status":   photo.Status,
			"sort":     photo.SortOrder,
			"file_id":  photo.FileID,
			"created_at": photo.CreatedAt,
		},
	})
}

// errDishNotFound 菜品不存在或不属于该食堂。
var errDishNotFound = errors.New("dish not found")

// errInvalidDishName 菜名为空。
var errInvalidDishName = errors.New("invalid dish name")

// errPendingPhotoExists 同一用户同一菜已有 pending 实拍。
var errPendingPhotoExists = errors.New("pending photo exists")
