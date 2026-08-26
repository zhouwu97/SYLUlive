package handlers

import (
	"net/http"
	"strconv"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

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

// ListDishes 公开菜品列表：所有 status=active 的菜都返回，是否有实拍由 photo_count 单独表达。
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
	canteen.NormalizeOperatingStatus()

	type dishRow struct {
		ID                     uint    `json:"id"`
		Name                   string  `json:"name"`
		CanteenID              uint    `json:"canteen_id"`
		CanteenName            string  `json:"canteen_name"`
		CanteenOperatingStatus string  `json:"canteen_operating_status"`
		CoverImage             string  `json:"cover_image"`
		PhotoCount             int     `json:"photo_count"`
		LastPhotoAt            string  `json:"last_photo_at"`
		AverageScore           float64 `json:"average_score"`
		ReviewerCount          int     `json:"reviewer_count"`
	}
	var dishes []dishRow
	// 每个菜独立聚合 approved 统计，无跨表笛卡尔积。
	err = h.db.Table("canteen_dishes AS d").
		Joins("JOIN canteens c ON c.id = d.canteen_id AND c.verified = ?", true).
		Select(`d.id, d.name, d.canteen_id, c.name AS canteen_name, c.operating_status AS canteen_operating_status,
			(SELECT f.path FROM canteen_dish_photos p
			 JOIN files f ON f.id = p.file_id
			 WHERE p.dish_id = d.id AND p.status = ?
			 ORDER BY p.sort_order, p.created_at, p.id LIMIT 1) AS cover_image,
			(SELECT COUNT(*) FROM canteen_dish_photos p
			 WHERE p.dish_id = d.id AND p.status = ?) AS photo_count,
			(SELECT MAX(p.created_at) FROM canteen_dish_photos p
			 WHERE p.dish_id = d.id AND p.status = ?) AS last_photo_at`,
			models.DishPhotoStatusApproved, models.DishPhotoStatusApproved, models.DishPhotoStatusApproved).
		Where("d.canteen_id = ? AND d.status = ?", canteenID, models.DishStatusActive).
		Order("photo_count DESC, d.created_at DESC").
		Scan(&dishes).Error
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取菜品列表失败"})
		return
	}
	if dishes == nil {
		dishes = []dishRow{}
	}
	for i := range dishes {
		if dishes[i].CanteenOperatingStatus == "" {
			dishes[i].CanteenOperatingStatus = models.CanteenOperatingActive
		}
	}
	for i := range dishes {
		var summaries []models.CanteenDishRatingSummary
		if h.db.Preload("User").Where("dish_id = ?", dishes[i].ID).Find(&summaries).Error == nil {
			samples := make([]services.DishRatingSample, 0, len(summaries))
			for _, summary := range summaries {
				weight := 1.0
				if summary.User != nil {
					weight = services.ComputeCreditWeight(summary.User.CreditScore)
				}
				samples = append(samples, services.DishRatingSample{
					Overall: summary.EffectiveScore, Taste: summary.TasteScore,
					Value: summary.ValueScore, Portion: summary.PortionScore, Weight: weight,
				})
			}
			agg := services.ComputeDishAggregate(samples)
			dishes[i].AverageScore, dishes[i].ReviewerCount = agg.AverageScore, agg.ReviewerCount
		}
	}
	c.JSON(http.StatusOK, dishes)
}

// GetDish 公开菜品详情：dish + approved 实拍列表。
// GET /api/canteens/:canteenId/dishes/:dishId
func (h *CanteenDishHandler) GetDish(c *gin.Context) {
	canteenIDStr := c.Param("id")
	if canteenIDStr == "" {
		canteenIDStr = c.Param("canteenId")
	}
	canteenID, err := strconv.ParseUint(canteenIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	dishID, err := strconv.ParseUint(c.Param("dishId"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效菜品ID"})
		return
	}
	var canteen models.Canteen
	if err := h.db.Where("id = ? AND verified = ?", canteenID, true).First(&canteen).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}
	canteen.NormalizeOperatingStatus()

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
	var summaries []models.CanteenDishRatingSummary
	_ = h.db.Preload("User").Where("dish_id = ?", dishID).Find(&summaries).Error
	samples := make([]services.DishRatingSample, 0, len(summaries))
	for _, summary := range summaries {
		weight := 1.0
		if summary.User != nil {
			weight = services.ComputeCreditWeight(summary.User.CreditScore)
		}
		samples = append(samples, services.DishRatingSample{
			Overall: summary.EffectiveScore, Taste: summary.TasteScore,
			Value: summary.ValueScore, Portion: summary.PortionScore, Weight: weight,
		})
	}
	agg := services.ComputeDishAggregate(samples)

	c.JSON(http.StatusOK, gin.H{
		"dish": gin.H{
			"id":                       dish.ID,
			"name":                     dish.Name,
			"canteen_id":               dish.CanteenID,
			"canteen_name":             canteen.Name,
			"canteen_operating_status": canteen.OperatingStatus,
		},
		"photo_count":    len(photos),
		"photos":         photos,
		"average_score":  agg.AverageScore,
		"reviewer_count": agg.ReviewerCount,
		"dimension_scores": gin.H{
			"taste":   agg.TasteScore,
			"value":   agg.ValueScore,
			"portion": agg.PortionScore,
		},
	})
}
