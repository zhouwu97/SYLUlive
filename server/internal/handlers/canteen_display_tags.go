package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// GetDisplayTags returns the administrator's override, or null for automatic aggregation.
func (h *CanteenHandler) GetDisplayTags(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 32)
	if err != nil || id == 0 {
		c.JSON(400, gin.H{"error": "无效ID"})
		return
	}
	var shop models.Canteen
	if err := h.db.Where("verified = ?", true).First(&shop, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(404, gin.H{"error": "店铺不存在"})
		} else {
			c.JSON(500, gin.H{"error": "获取标签失败"})
		}
		return
	}
	var tags []string
	if shop.DisplayTags != nil {
		if json.Unmarshal([]byte(*shop.DisplayTags), &tags) != nil {
			c.JSON(500, gin.H{"error": "标签数据无效"})
			return
		}
	}
	automaticTags, err := h.aggregateSummaryTags(shop.ID, summaryTagDays, 3)
	if err != nil {
		c.JSON(500, gin.H{"error": "获取评价标签失败"})
		return
	}
	if automaticTags == nil {
		automaticTags = []services.SummaryTag{}
	}
	c.JSON(200, gin.H{"location_area": shop.LocationArea, "location_floor": shop.LocationFloor,
		"tags": tags, "automatic_tags": automaticTags})
}

func (h *CanteenHandler) UpdateDisplayTags(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 32)
	if err != nil || id == 0 {
		c.JSON(400, gin.H{"error": "无效ID"})
		return
	}
	var input struct {
		Area  *string         `json:"location_area"`
		Floor *string         `json:"location_floor"`
		Tags  json.RawMessage `json:"tags"`
	}
	if c.ShouldBindJSON(&input) != nil || input.Area == nil || input.Floor == nil || len(input.Tags) == 0 {
		c.JSON(400, gin.H{"error": "请完整填写位置和标签设置"})
		return
	}
	area, floor := strings.TrimSpace(*input.Area), strings.TrimSpace(*input.Floor)
	if !models.IsValidCanteenLocationArea(area) || !models.IsValidCanteenLocationFloor(floor) {
		c.JSON(400, gin.H{"error": "位置标签无效"})
		return
	}
	displayTags, err := parseCanteenDisplayTags(input.Tags)
	if err != nil {
		c.JSON(400, gin.H{"error": err.Error()})
		return
	}
	adminID, ok := c.Get("user_id")
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录"})
		return
	}
	err = h.db.Transaction(func(tx *gorm.DB) error {
		if err := services.RequireCanteenArchiveWrite(tx, uint(id), c.GetUint("user_id")); err != nil {
			return err
		}
		var shop models.Canteen
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("verified = ?", true).First(&shop, id).Error; err != nil {
			return err
		}
		var count int64
		if err := tx.Model(&models.Canteen{}).Where("id <> ? AND normalized_name = ? AND location_area = ? AND location_floor = ?", shop.ID, shop.NormalizedName, area, floor).Count(&count).Error; err != nil {
			return err
		}
		if count > 0 {
			return errCanteenLocationConflict
		}
		var admin models.User
		if err := tx.Select("nickname").First(&admin, adminID).Error; err != nil {
			return err
		}
		oldArea, oldFloor := shop.LocationArea, shop.LocationFloor
		if err := tx.Model(&shop).Updates(map[string]interface{}{"location_area": area, "location_floor": floor, "display_tags": displayTags}).Error; err != nil {
			return err
		}
		return tx.Create(&models.AdminLog{AdminID: adminID.(uint), AdminName: admin.Nickname, Action: "修改店铺标签", Target: shop.Name, Detail: fmt.Sprintf("店铺 ID: %d；位置：%s/%s → %s/%s；展示标签：%s", shop.ID, oldArea, oldFloor, area, floor, string(input.Tags))}).Error
	})
	if err != nil {
		if respondCanteenArchivePermission(c, err) {
			return
		}
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(404, gin.H{"error": "店铺不存在"})
		} else if errors.Is(err, errCanteenLocationConflict) || strings.Contains(strings.ToLower(err.Error()), "unique") {
			c.JSON(409, gin.H{"error": "该位置已有同名店铺"})
		} else {
			c.JSON(500, gin.H{"error": "保存标签失败，请重试"})
		}
		return
	}
	canteenDiscoveryCache.Invalidate()
	c.JSON(200, gin.H{"message": "保存成功"})
}

var errCanteenLocationConflict = errors.New("canteen location conflict")

// 新统一编辑入口与旧版标签接口使用同一校验，保留 null 自动、[] 隐藏的语义。
func parseCanteenDisplayTags(raw json.RawMessage) (*string, error) {
	if strings.TrimSpace(string(raw)) == "null" {
		return nil, nil
	}
	var tags []string
	if json.Unmarshal(raw, &tags) != nil || tags == nil || len(tags) > 3 {
		return nil, errors.New("最多选择三个有效标签")
	}
	seen := map[string]bool{}
	for _, key := range tags {
		if _, ok := services.CanteenTagName[key]; !ok || seen[key] {
			return nil, errors.New("标签无效或重复")
		}
		seen[key] = true
	}
	encoded, _ := json.Marshal(tags)
	value := string(encoded)
	return &value, nil
}
