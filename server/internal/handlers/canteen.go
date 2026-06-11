package handlers

import (
	"fmt"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

type CanteenHandler struct {
	db *gorm.DB
}

func NewCanteenHandler(db *gorm.DB) *CanteenHandler {
	return &CanteenHandler{db: db}
}

// GetList 获取食堂列表（按评分降序排列）
func (h *CanteenHandler) GetList(c *gin.Context) {
	var canteens []models.Canteen
	if err := h.db.Where("verified = ?", true).Order("created_at DESC").Find(&canteens).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取食堂列表失败"})
		return
	}

	type CanteenWithStats struct {
		models.Canteen
		RatingCount int     `json:"rating_count"`
		AverageStar float64 `json:"average_star"`
	}
	result := make([]CanteenWithStats, len(canteens))
	for i, ct := range canteens {
		result[i].Canteen = ct
		var count int64
		var avg float64
		h.db.Model(&models.CanteenRating{}).Where("canteen_id = ?", ct.ID).Count(&count)
		if count > 0 {
			h.db.Model(&models.CanteenRating{}).Where("canteen_id = ?", ct.ID).Select("AVG(CAST(star AS FLOAT))").Scan(&avg)
		}
		result[i].RatingCount = int(count)
		result[i].AverageStar = avg
	}

	// 按平均分从高到低排序，如果分数相同按评价人数，再按ID
	for i := 0; i < len(result); i++ {
		for j := i + 1; j < len(result); j++ {
			if result[j].AverageStar > result[i].AverageStar || 
				(result[j].AverageStar == result[i].AverageStar && result[j].RatingCount > result[i].RatingCount) {
				result[i], result[j] = result[j], result[i]
			}
		}
	}

	c.JSON(http.StatusOK, result)
}

// GetDetail 食堂详情（含评价列表）
func (h *CanteenHandler) GetDetail(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	var canteen models.Canteen
	if err := h.db.First(&canteen, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}

	var ratings []models.CanteenRating
	h.db.Where("canteen_id = ?", id).Preload("User").Order("created_at DESC").Find(&ratings)
	for i := range ratings {
		if ratings[i].User != nil {
			ratings[i].UserName = ratings[i].User.Nickname
			ratings[i].UserStudentID = ratings[i].User.StudentID
			ratings[i].UserAvatar = ratings[i].User.Avatar
		}
	}

	var count int64
	var avg float64
	h.db.Model(&models.CanteenRating{}).Where("canteen_id = ?", id).Count(&count)
	if count > 0 {
		h.db.Model(&models.CanteenRating{}).Where("canteen_id = ?", id).Select("AVG(CAST(star AS FLOAT))").Scan(&avg)
	}

	var myRating *models.CanteenRating
	if userID, exists := c.Get("user_id"); exists {
		var rating models.CanteenRating
		if err := h.db.Where("canteen_id = ? AND user_id = ?", id, userID).First(&rating).Error; err == nil {
			var user models.User
			if err := h.db.Select("nickname, student_id, avatar").First(&user, rating.UserID).Error; err == nil {
				rating.UserName = user.Nickname
				rating.UserStudentID = user.StudentID
				rating.UserAvatar = user.Avatar
			}
			myRating = &rating
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"canteen":      canteen,
		"ratings":      ratings,
		"rating_count": count,
		"average_star": avg,
		"my_rating":    myRating,
	})
}

// Create 添加食堂（用户提交即通过，+10经验）
func (h *CanteenHandler) Create(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var input struct {
		Name  string `json:"name" binding:"required"`
		Image string `json:"image" binding:"required"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	canteen := models.Canteen{
		Name:      input.Name,
		Image:     input.Image,
		Verified:  true,
		CreatedBy: userID.(uint),
	}

	if err := h.db.Create(&canteen).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "添加失败"})
		return
	}

	// 增加10经验
	h.db.Model(&models.User{}).Where("id = ?", userID).UpdateColumn("exp", gorm.Expr("exp + ?", 10))

	c.JSON(http.StatusCreated, gin.H{
		"message": "添加成功，经验+10",
		"canteen": canteen,
	})
}

// Rate 评价食堂
func (h *CanteenHandler) Rate(c *gin.Context) {
	userID, _ := c.Get("user_id")
	cid, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}

	var input struct {
		Star    int    `json:"star" binding:"required,min=1,max=5"`
		Comment string `json:"comment" binding:"max=500"`
		Images  string `json:"images"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	var canteen models.Canteen
	if err := h.db.First(&canteen, cid).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}

	var rating models.CanteenRating
	err = h.db.Where("canteen_id = ? AND user_id = ?", cid, userID).First(&rating).Error
	if err == nil {
		// 已存在则更新
		h.db.Model(&rating).Updates(map[string]interface{}{
			"star":    input.Star,
			"comment": input.Comment,
			"images":  input.Images,
		})
		c.JSON(http.StatusOK, gin.H{"message": "评价已更新", "rating": rating})
	} else {
		// 新建
		rating = models.CanteenRating{
			CanteenID: uint(cid),
			UserID:    userID.(uint),
			Star:      input.Star,
			Comment:   input.Comment,
			Images:    input.Images,
		}
		h.db.Create(&rating)
		c.JSON(http.StatusCreated, gin.H{"message": "评价成功", "rating": rating})
	}
}

// DeleteCanteen 管理员删除食堂（驳回并扣除10经验）
func (h *CanteenHandler) DeleteCanteen(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}

	var canteen models.Canteen
	if err := h.db.First(&canteen, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}

	// 扣除10经验 (保证不为负数可以做个判断，但简单处理直接减也可以，或者用 gorm expr 保证 > 0)
	h.db.Exec("UPDATE users SET exp = CASE WHEN exp >= 10 THEN exp - 10 ELSE 0 END WHERE id = ?", canteen.CreatedBy)

	// 删除关联的评价
	h.db.Where("canteen_id = ?", id).Delete(&models.CanteenRating{})
	// 删除食堂
	h.db.Delete(&canteen)

	// 记录管理员操作
	adminID, _ := c.Get("user_id")
	var admin models.User
	h.db.Select("nickname").First(&admin, adminID)
	h.db.Create(&models.AdminLog{
		AdminID:   adminID.(uint),
		AdminName: admin.Nickname,
		Action:    "删除食堂",
		Target:    canteen.Name,
		Detail:    fmt.Sprintf("驳回食堂提交，扣除用户 %d 的10点经验", canteen.CreatedBy),
	})

	c.JSON(http.StatusOK, gin.H{"message": "已删除并驳回经验"})
}
