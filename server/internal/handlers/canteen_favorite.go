package handlers

import (
	"net/http"
	"strconv"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm/clause"
)

func parseFavoriteCanteenID(c *gin.Context) (uint, bool) {
	id, err := strconv.ParseUint(c.Param("id"), 10, strconv.IntSize)
	if err != nil || id == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return 0, false
	}
	return uint(id), true
}

// AddFavorite 收藏商家（幂等）。已下架的店也可以收藏，方便恢复营业后找回。
// PUT /api/user/canteen-favorites/:id
func (h *CanteenHandler) AddFavorite(c *gin.Context) {
	userID, ok := authenticatedUserID(c)
	if !ok {
		return
	}
	canteenID, ok := parseFavoriteCanteenID(c)
	if !ok {
		return
	}
	var canteen models.Canteen
	if err := h.db.Select("id", "verified").First(&canteen, canteenID).Error; err != nil || !canteen.Verified {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}
	if err := h.db.Clauses(clause.OnConflict{DoNothing: true}).
		Create(&models.CanteenFavorite{UserID: userID, CanteenID: canteenID}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "收藏失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"favorited": true})
}

// RemoveFavorite 取消收藏（幂等）。
// DELETE /api/user/canteen-favorites/:id
func (h *CanteenHandler) RemoveFavorite(c *gin.Context) {
	userID, ok := authenticatedUserID(c)
	if !ok {
		return
	}
	canteenID, ok := parseFavoriteCanteenID(c)
	if !ok {
		return
	}
	if err := h.db.Where("user_id = ? AND canteen_id = ?", userID, canteenID).
		Delete(&models.CanteenFavorite{}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "取消收藏失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"favorited": false})
}

// ListFavorites 我收藏的商家，最近收藏的在前；只返回仍公开的店，并带上当前评分摘要。
// GET /api/user/canteen-favorites
func (h *CanteenHandler) ListFavorites(c *gin.Context) {
	userID, ok := authenticatedUserID(c)
	if !ok {
		return
	}
	var favorites []models.CanteenFavorite
	if err := h.db.Where("user_id = ?", userID).Order("created_at DESC, id DESC").Find(&favorites).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取收藏失败"})
		return
	}
	ids := make([]uint, 0, len(favorites))
	for _, favorite := range favorites {
		ids = append(ids, favorite.CanteenID)
	}
	rows, err := h.queryCanteenStatsFor(ids, true)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取收藏失败"})
		return
	}
	byID := make(map[uint]canteenStatsRow, len(rows))
	for _, row := range rows {
		byID[row.ID] = row
	}
	items := make([]canteenStatsRow, 0, len(favorites))
	for _, favorite := range favorites {
		if row, ok := byID[favorite.CanteenID]; ok {
			items = append(items, row)
		}
	}
	c.JSON(http.StatusOK, gin.H{"items": items})
}

// isFavoriteCanteen 当前用户是否收藏了这家店；未登录或查询失败按未收藏处理。
func (h *CanteenHandler) isFavoriteCanteen(userID, canteenID uint) bool {
	if userID == 0 {
		return false
	}
	var count int64
	if err := h.db.Model(&models.CanteenFavorite{}).
		Where("user_id = ? AND canteen_id = ?", userID, canteenID).Count(&count).Error; err != nil {
		return false
	}
	return count > 0
}
