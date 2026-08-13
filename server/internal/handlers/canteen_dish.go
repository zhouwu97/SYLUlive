package handlers

import (
	"net/http"
	"strconv"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// CanteenDishHandler 公开菜品图库接口（approved-only）。
type CanteenDishHandler struct {
	db *gorm.DB
}

func NewCanteenDishHandler(db *gorm.DB) *CanteenDishHandler {
	return &CanteenDishHandler{db: db}
}

// ListDishes 公开菜品列表：仅返回 status=active 且 approved 实拍 > 0 的菜。
// 使用独立聚合子查询，避免 LEFT JOIN 膨胀污染 COUNT。
// GET /api/canteens/:id/dishes
func (h *CanteenDishHandler) ListDishes(c *gin.Context) {
	canteenID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}

	var canteen models.Canteen
	if err := h.db.First(&canteen, canteenID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}
	if !canteen.Verified {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}

	type dishRow struct {
		ID          uint   `json:"id"`
		Name        string `json:"name"`
		CoverImage  string `json:"cover_image"`
		PhotoCount  int    `json:"photo_count"`
		LastPhotoAt string `json:"last_photo_at"`
	}
	var dishes []dishRow
	// 每个菜独立聚合 approved 统计，无跨表笛卡尔积。
	// EXISTS 过滤无 approved 实拍的菜，photo_count 仅作为选择列。
	err = h.db.Table("canteen_dishes AS d").
		Select(`d.id, d.name,
			(SELECT f.path FROM canteen_dish_photos p
			 JOIN files f ON f.id = p.file_id
			 WHERE p.dish_id = d.id AND p.status = ?
			 ORDER BY p.sort_order, p.created_at, p.id LIMIT 1) AS cover_image,
			(SELECT COUNT(*) FROM canteen_dish_photos p
			 WHERE p.dish_id = d.id AND p.status = ?) AS photo_count,
			(SELECT MAX(p.created_at) FROM canteen_dish_photos p
			 WHERE p.dish_id = d.id AND p.status = ?) AS last_photo_at`,
			models.DishPhotoStatusApproved, models.DishPhotoStatusApproved, models.DishPhotoStatusApproved).
		Where("d.canteen_id = ? AND d.status = ? AND EXISTS (SELECT 1 FROM canteen_dish_photos p WHERE p.dish_id = d.id AND p.status = ?)",
			canteenID, models.DishStatusActive, models.DishPhotoStatusApproved).
		Order("photo_count DESC, d.created_at DESC").
		Scan(&dishes).Error
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取菜品列表失败"})
		return
	}
	if dishes == nil {
		dishes = []dishRow{}
	}
	c.JSON(http.StatusOK, dishes)
}

// GetDish 公开菜品详情：dish + approved 实拍列表。
// GET /api/canteens/:canteenId/dishes/:dishId
func (h *CanteenDishHandler) GetDish(c *gin.Context) {
	canteenID, err := strconv.ParseUint(c.Param("canteenId"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	dishID, err := strconv.ParseUint(c.Param("dishId"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效菜品ID"})
		return
	}

	var dish models.CanteenDish
	if err := h.db.Where("id = ? AND canteen_id = ? AND status = ?",
		dishID, canteenID, models.DishStatusActive).First(&dish).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "菜品不存在"})
		return
	}

	type photoRow struct {
		ID        uint   `json:"id"`
		Image     string `json:"image"`
		CreatedAt string `json:"created_at"`
	}
	var photos []photoRow
	// 只出 approved；按 sort_order / created_at 排序。
	err = h.db.Table("canteen_dish_photos AS p").
		Joins("JOIN files f ON f.id = p.file_id").
		Select("p.id, f.path AS image, p.created_at").
		Where("p.dish_id = ? AND p.status = ?", dishID, models.DishPhotoStatusApproved).
		Order("p.sort_order, p.created_at, p.id").
		Scan(&photos).Error
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取菜品实拍失败"})
		return
	}
	if photos == nil {
		photos = []photoRow{}
	}

	c.JSON(http.StatusOK, gin.H{
		"dish": gin.H{
			"id":         dish.ID,
			"name":       dish.Name,
			"canteen_id": dish.CanteenID,
		},
		"photo_count": len(photos),
		"photos":      photos,
	})
}
