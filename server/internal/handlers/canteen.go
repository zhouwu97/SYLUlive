package handlers

import (
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

type CanteenHandler struct {
	db *gorm.DB
}

func NewCanteenHandler(db *gorm.DB) *CanteenHandler {
	return &CanteenHandler{db: db}
}

// GetList 获取食堂列表（按评分降序排列）
func (h *CanteenHandler) GetList(c *gin.Context) {
	type CanteenWithStats struct {
		models.Canteen
		RatingCount int     `json:"rating_count"`
		AverageStar float64 `json:"average_star"`
	}
	var result []CanteenWithStats

	// 修复 N+1 查询，使用 LEFT JOIN 与 GROUP BY 一次性查出评分统计
	err := h.db.Table("canteens").
		Select("canteens.*, COUNT(canteen_ratings.id) as rating_count, COALESCE(AVG(CAST(canteen_ratings.star AS FLOAT)), 0) as average_star").
		Joins("LEFT JOIN canteen_ratings ON canteen_ratings.canteen_id = canteens.id").
		Where("canteens.verified = ?", true).
		Group("canteens.id").
		Order("average_star DESC, rating_count DESC, canteens.created_at DESC").
		Find(&result).Error

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取食堂列表失败"})
		return
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
	if err := h.db.Where("canteen_id = ?", id).Preload("User").Order("created_at DESC").Find(&ratings).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取评价列表失败"})
		return
	}
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
		if err := h.db.Create(&rating).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
			return
		}
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
	if err := h.db.Exec("UPDATE users SET exp = CASE WHEN exp >= 10 THEN exp - 10 ELSE 0 END WHERE id = ?", canteen.CreatedBy).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	// 删除关联的评价
	if err := h.db.Where("canteen_id = ?", id).Delete(&models.CanteenRating{}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除关联评价失败"})
		return
	}
	// 删除食堂
	if err := h.db.Delete(&canteen).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	// 记录管理员操作
	adminID, _ := c.Get("user_id")
	var admin models.User
	h.db.Select("nickname").First(&admin, adminID)
	if err := h.db.Create(&models.AdminLog{
		AdminID:   adminID.(uint),
		AdminName: admin.Nickname,
		Action:    "删除食堂",
		Target:    canteen.Name,
		Detail:    fmt.Sprintf("驳回食堂提交，扣除用户 %d 的10点经验", canteen.CreatedBy),
	}).Error; err != nil {
		log.Printf("[DB_WARN] Failed to write admin log: %v", err)
	}

	c.JSON(http.StatusOK, gin.H{"message": "已删除并驳回经验"})
}

// UpdateImage 管理员修改食堂图片
func (h *CanteenHandler) UpdateImage(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}

	var input struct {
		Image string `json:"image" binding:"required,url|filepath"` // 可以用 custom validation，这里简单要求 required
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "图片地址不能为空"})
		return
	}

	image := strings.TrimSpace(input.Image)
	if image == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "图片地址不能为空"})
		return
	}

	if !strings.HasPrefix(image, "/uploads/") {
		c.JSON(http.StatusBadRequest, gin.H{"error": "图片地址必须来自站内上传"})
		return
	}
	
	input.Image = image

	// 开启事务
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var canteen models.Canteen
		if err := tx.First(&canteen, id).Error; err != nil {
			return fmt.Errorf("食堂不存在")
		}

		oldImage := canteen.Image
		canteen.Image = input.Image

		if err := tx.Save(&canteen).Error; err != nil {
			return fmt.Errorf("更新食堂图片失败")
		}

		// 记录管理员操作
		adminID, _ := c.Get("user_id")
		var admin models.User
		if err := tx.Select("nickname").First(&admin, adminID).Error; err != nil {
			return fmt.Errorf("获取管理员信息失败")
		}

		detail := fmt.Sprintf("管理员修改食堂图片： %s（ID: %d），旧图片：%s，新图片：%s", canteen.Name, canteen.ID, oldImage, input.Image)
		
		if err := tx.Create(&models.AdminLog{
			AdminID:   adminID.(uint),
			AdminName: admin.Nickname,
			Action:    "修改食堂图片",
			Target:    canteen.Name,
			Detail:    detail,
		}).Error; err != nil {
			return fmt.Errorf("记录管理员操作失败")
		}

		// 返回给外部使用
		c.Set("updated_canteen", canteen)
		return nil
	})

	if err != nil {
		if err.Error() == "食堂不存在" {
			c.JSON(http.StatusNotFound, gin.H{"error": err.Error()})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		}
		return
	}

	updatedCanteen, _ := c.Get("updated_canteen")
	c.JSON(http.StatusOK, gin.H{
		"message": "食堂图片已更新",
		"canteen": updatedCanteen,
	})
}
