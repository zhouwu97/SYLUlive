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
			oldName, oldNormalized := dish.Name, dish.NormalizedName
			if err := tx.Model(&dish).Updates(map[string]interface{}{
				"name": name, "normalized_name": normalized,
			}).Error; err != nil {
				return err
			}
			// 旧名留作别名：同学继续输入旧名时会落到改名后的这道菜，不会重新长出重复菜。
			if oldNormalized != "" && oldNormalized != normalized {
				if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&models.CanteenDishAlias{
					CanteenID: dish.CanteenID, DishID: dish.ID, Alias: oldName,
					NormalizedAlias: oldNormalized, CreatedBy: adminID,
				}).Error; err != nil {
					return err
				}
			}
		}
		if input.Status != nil {
			if err := tx.Model(&dish).Update("status", *input.Status).Error; err != nil {
				return err
			}
			if err := services.ReconcileDishPhotoPublicAccess(tx, dish.ID); err != nil {
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

// SetDishPhotoCover 管理员把一张已公开实拍设为菜品封面；其余实拍按时间倒序排在后面。
// POST /api/canteens/dish-photos/:photoId/cover
func (h *CanteenDishPhotoAdminHandler) SetDishPhotoCover(c *gin.Context) {
	photoID, err := strconv.ParseUint(c.Param("photoId"), 10, 64)
	if err != nil || photoID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	adminID := c.GetUint("user_id")
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var photo models.CanteenDishPhoto
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("id = ? AND status = ?", photoID, models.DishPhotoStatusApproved).First(&photo).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.CanteenDishPhoto{}).Where("dish_id = ?", photo.DishID).Update("sort_order", 0).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.CanteenDishPhoto{}).Where("id = ?", photo.ID).Update("sort_order", -1).Error; err != nil {
			return err
		}
		return tx.Create(&models.AdminLog{
			AdminID: adminID, AdminName: adminNickname(tx, adminID), Action: "设置菜品封面",
			Target: fmt.Sprintf("dish:%d", photo.DishID), Detail: fmt.Sprintf("实拍 %d 设为菜品 %d 的封面", photo.ID, photo.DishID),
		}).Error
	})
	if err != nil {
		respondDishPhotoAdminError(c, err)
		return
	}
	canteenDiscoveryCache.Invalidate()
	c.JSON(http.StatusOK, gin.H{"message": "已设为封面"})
}

// AdminListDishes 管理端菜品列表：同时列出上架和已隐藏的菜，供改名、隐藏/恢复与合并使用。
// 已合并的菜只作为别名存在，不再出现在列表里。
// GET /api/canteens/:id/admin-dishes
func (h *CanteenDishPhotoAdminHandler) AdminListDishes(c *gin.Context) {
	canteenID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || canteenID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	var canteen models.Canteen
	if err := h.db.Select("id").First(&canteen, canteenID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}
	type dishRow struct {
		ID           uint      `json:"id"`
		Name         string    `json:"name"`
		Status       string    `json:"status"`
		PhotoCount   int       `json:"photo_count"`
		MentionCount int       `json:"mention_count"`
		CreatedAt    time.Time `json:"created_at"`
	}
	rows := make([]dishRow, 0)
	if err := h.db.Table("canteen_dishes AS d").
		Select(`d.id, d.name, d.status, d.created_at,
			(SELECT COUNT(*) FROM canteen_dish_photos p WHERE p.dish_id = d.id AND p.status = ?) AS photo_count,
			(SELECT COUNT(DISTINCT red.review_event_id) FROM canteen_review_event_dishes red
			 JOIN canteen_review_events re ON re.id = red.review_event_id
			 WHERE red.dish_id = d.id AND re.status = ?) AS mention_count`,
			models.DishPhotoStatusApproved, models.ReviewEventStatusActive).
		Where("d.canteen_id = ? AND d.status IN ?", canteenID, []string{models.DishStatusActive, models.DishStatusHidden}).
		Order("CASE WHEN d.status = 'active' THEN 0 ELSE 1 END, d.name ASC, d.id ASC").
		Scan(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取菜品列表失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": rows})
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
