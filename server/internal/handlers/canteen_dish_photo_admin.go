package handlers

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"shenliyuan/internal/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// CanteenDishPhotoAdminHandler 菜品与实拍事后治理管理接口。
type CanteenDishPhotoAdminHandler struct {
	db *gorm.DB
}

func NewCanteenDishPhotoAdminHandler(db *gorm.DB) *CanteenDishPhotoAdminHandler {
	return &CanteenDishPhotoAdminHandler{db: db}
}

// ArchiveDishPhoto 下架实拍：approved → archived，业务不再展示，并回收孤儿文件公开权限。
// POST /api/canteens/dish-photos/:photoId/archive
func (h *CanteenDishPhotoAdminHandler) ArchiveDishPhoto(c *gin.Context) {
	photoID, err := strconv.ParseUint(c.Param("photoId"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	adminID := c.GetUint("user_id")

	var photo models.CanteenDishPhoto
	err = h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&photo, photoID).Error; err != nil {
			return err
		}
		if photo.Status != models.DishPhotoStatusApproved {
			return errDishPhotoAlreadyReviewed
		}
		var dish models.CanteenDish
		if err := tx.First(&dish, photo.DishID).Error; err != nil {
			return err
		}
		now := time.Now()
		if err := tx.Model(&photo).Updates(map[string]interface{}{
			"status":      models.DishPhotoStatusArchived,
			"reviewed_by": adminID,
			"reviewed_at": &now,
		}).Error; err != nil {
			return err
		}
		// 检查若无其他有效公开业务引用，回收 File public 权限降级为 private
		if err := services.ReconcileFilePublicAccess(tx, photo.FileID); err != nil {
			return err
		}
		return tx.Create(&models.AdminLog{
			AdminID: adminID, AdminName: adminNickname(tx, adminID),
			Action: "下架菜品实拍", Target: dish.Name,
			Detail: fmt.Sprintf("下架菜品实拍（photo ID: %d）", photo.ID),
		}).Error
	})
	if err != nil {
		respondDishPhotoAdminError(c, err)
		return
	}
	canteenDiscoveryCache.Invalidate()
	c.JSON(http.StatusOK, gin.H{"message": "已下架", "photo_id": photo.ID})
}

// AdminGetDishPhotoDetail 管理员查看单张实拍详情（含上传者信息）。
// GET /api/canteens/dish-photos/:photoId
func (h *CanteenDishPhotoAdminHandler) AdminGetDishPhotoDetail(c *gin.Context) {
	photoID, err := strconv.ParseUint(c.Param("photoId"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	type detailRow struct {
		ID           uint      `json:"id"`
		DishID       uint      `json:"dish_id"`
		DishName     string    `json:"dish_name"`
		FileID       uint      `json:"file_id"`
		Image        string    `json:"image"`
		UploaderID   uint      `json:"uploader_id"`
		UploaderName string    `json:"uploader_name"`
		Status       string    `json:"status"`
		CreatedAt    time.Time `json:"created_at"`
	}
	var row detailRow
	err = h.db.Table("canteen_dish_photos AS p").
		Joins("JOIN canteen_dishes d ON d.id = p.dish_id").
		Joins("JOIN files f ON f.id = p.file_id").
		Joins("JOIN users u ON u.id = p.user_id").
		Select(`p.id, p.dish_id, d.name AS dish_name, p.file_id,
			f.path AS image, p.user_id AS uploader_id, u.nickname AS uploader_name,
			p.status, p.created_at`).
		Where("p.id = ?", photoID).
		Scan(&row).Error
	if err != nil || row.ID == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "实拍记录不存在"})
		return
	}
	c.JSON(http.StatusOK, row)
}

// AdminUpdateDish 管理员修改菜品：重命名 / 隐藏。
// PATCH /api/canteens/dishes/:dishId  body: {"name": "..."} 或 {"status": "hidden"}
func (h *CanteenDishPhotoAdminHandler) AdminUpdateDish(c *gin.Context) {
	dishID, err := strconv.ParseUint(c.Param("dishId"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	var input struct {
		Name   *string `json:"name"`
		Status *string `json:"status"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误"})
		return
	}
	if input.Name == nil && input.Status == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请提供 name 或 status"})
		return
	}
	if input.Status != nil && *input.Status != models.DishStatusActive && *input.Status != models.DishStatusHidden {
		c.JSON(http.StatusBadRequest, gin.H{"error": "status 只能为 active 或 hidden"})
		return
	}
	adminID := c.GetUint("user_id")

	var dish models.CanteenDish
	err = h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&dish, dishID).Error; err != nil {
			return err
		}
		if input.Name != nil {
			name := strings.TrimSpace(*input.Name)
			if name == "" {
				return errInvalidDishName
			}
			if utils.CountGraphemes(name) > 100 {
				return errDishNameTooLong
			}
			normalized := utils.NormalizeDishName(name)
			// 同食堂重名检查（唯一索引兜底）
			var conflict int64
			if err := tx.Model(&models.CanteenDish{}).
				Where("canteen_id = ? AND normalized_name = ? AND id <> ?", dish.CanteenID, normalized, dish.ID).
				Count(&conflict).Error; err != nil {
				return err
			}
			if conflict > 0 {
				return errDishNameConflict
			}
			if err := tx.Model(&dish).Updates(map[string]interface{}{
				"name": name, "normalized_name": normalized,
			}).Error; err != nil {
				return err
			}
		}
		if input.Status != nil {
			if err := tx.Model(&dish).Update("status", *input.Status).Error; err != nil {
				return err
			}
		}
		return tx.Create(&models.AdminLog{
			AdminID: adminID, AdminName: adminNickname(tx, adminID),
			Action: dishUpdateAction(input.Name != nil, input.Status != nil), Target: dish.Name,
			Detail: fmt.Sprintf("修改菜品（dish ID: %d）", dish.ID),
		}).Error
	})
	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "菜品不存在"})
		case errors.Is(err, errInvalidDishName):
			c.JSON(http.StatusBadRequest, gin.H{"error": "菜名不能为空"})
		case errors.Is(err, errDishNameTooLong):
			c.JSON(http.StatusBadRequest, gin.H{"error": "菜名不能超过 100 个字符"})
		case errors.Is(err, errDishNameConflict):
			c.JSON(http.StatusConflict, gin.H{"error": "该食堂已存在同名菜品"})
		case isUniqueConstraintError(err):
			c.JSON(http.StatusConflict, gin.H{"error": "该食堂已存在同名菜品"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "修改菜品失败"})
		}
		return
	}
	canteenDiscoveryCache.Invalidate()
	c.JSON(http.StatusOK, gin.H{"message": "已更新", "dish": dish})
}

// ── 辅助 ────────────────────────────────────────────────────────────

func dishUpdateAction(hasName, hasStatus bool) string {
	switch {
	case hasName && hasStatus:
		return "修改菜品"
	case hasName:
		return "重命名菜品"
	default:
		return "修改菜品状态"
	}
}

func adminNickname(tx *gorm.DB, adminID uint) string {
	var admin models.User
	if err := tx.Select("nickname").First(&admin, adminID).Error; err != nil {
		return ""
	}
	return admin.Nickname
}

func respondDishPhotoAdminError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, gorm.ErrRecordNotFound):
		c.JSON(http.StatusNotFound, gin.H{"error": "实拍记录不存在"})
	case errors.Is(err, errDishPhotoAlreadyReviewed):
		c.JSON(http.StatusConflict, gin.H{"code": "already_reviewed", "error": "该实拍已被处理"})
	case errors.Is(err, errDishGalleryFull):
		c.JSON(http.StatusConflict, gin.H{"code": "dish_gallery_full", "error": "该菜品已有3张审核实拍"})
	case errors.Is(err, errDishHidden):
		c.JSON(http.StatusConflict, gin.H{"code": "dish_hidden_requires_restore", "error": "该菜品已下架，请先恢复或合并菜品后再审核实拍"})
	default:
		c.JSON(http.StatusInternalServerError, gin.H{"error": "操作失败"})
	}
}

// errDishNameTooLong 菜名超长。
var errDishNameTooLong = errors.New("dish name too long")

// errDishNameConflict 同食堂重名。
var errDishNameConflict = errors.New("dish name conflict")

// errDishHidden 下架菜品不能通过审核重新产生公开图片引用。
var errDishHidden = errors.New("dish is hidden")
