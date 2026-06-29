package handlers

import (
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
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

	reviewSort := c.DefaultQuery("review_sort", "best")
	reviewFilter := c.DefaultQuery("review_filter", "all")

	ratingQuery := h.db.Where("canteen_id = ?", id).Preload("User")
	switch reviewFilter {
	case "with_image":
		ratingQuery = ratingQuery.Where("images IS NOT NULL AND images <> '' AND images <> '[]'")
	case "high":
		ratingQuery = ratingQuery.Where("star >= ?", 4)
	case "low":
		ratingQuery = ratingQuery.Where("star <= ?", 2)
	case "all":
	default:
		reviewFilter = "all"
	}

	switch reviewSort {
	case "latest":
		ratingQuery = ratingQuery.Order("created_at DESC")
	case "best":
		ratingQuery = ratingQuery.
			Order("(helpful_count - unhelpful_count * 2) DESC").
			Order("CASE WHEN comment IS NOT NULL AND TRIM(comment) <> '' THEN 1 ELSE 0 END DESC").
			Order("helpful_count DESC").
			Order("star DESC").
			Order("created_at DESC")
	default:
		reviewSort = "best"
		ratingQuery = ratingQuery.
			Order("(helpful_count - unhelpful_count * 2) DESC").
			Order("CASE WHEN comment IS NOT NULL AND TRIM(comment) <> '' THEN 1 ELSE 0 END DESC").
			Order("helpful_count DESC").
			Order("star DESC").
			Order("created_at DESC")
	}

	var ratings []models.CanteenRating
	if err := ratingQuery.Find(&ratings).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取评价列表失败"})
		return
	}

	var ratingIDs []uint
	for i := range ratings {
		ratingIDs = append(ratingIDs, ratings[i].ID)
	}
	voteByRatingID := map[uint]string{}
	if userID, exists := c.Get("user_id"); exists && len(ratingIDs) > 0 {
		var votes []models.CanteenRatingVote
		if err := h.db.Where("rating_id IN ? AND user_id = ?", ratingIDs, userID).Find(&votes).Error; err == nil {
			for _, vote := range votes {
				voteByRatingID[vote.RatingID] = vote.VoteType
			}
		}
	}

	for i := range ratings {
		if ratings[i].User != nil {
			ratings[i].UserName = ratings[i].User.Nickname
			ratings[i].UserStudentID = ratings[i].User.StudentID
			ratings[i].UserAvatar = ratings[i].User.Avatar
		}
		if vote, ok := voteByRatingID[ratings[i].ID]; ok {
			ratings[i].MyVote = &vote
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

// VoteRating 给食堂评价点赞/点踩/取消投票
func (h *CanteenHandler) VoteRating(c *gin.Context) {
	userIDAny, _ := c.Get("user_id")
	userID := userIDAny.(uint)

	ratingID64, err := strconv.ParseUint(c.Param("ratingId"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效评价ID"})
		return
	}
	ratingID := uint(ratingID64)

	var input struct {
		Vote string `json:"vote" binding:"required"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误"})
		return
	}
	if input.Vote != "up" && input.Vote != "down" && input.Vote != "none" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "投票类型不合法"})
		return
	}

	var updated models.CanteenRating
	myVote := input.Vote
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var rating models.CanteenRating
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&rating, ratingID).Error; err != nil {
			return err
		}
		if rating.UserID == userID {
			return errVoteOwnRating
		}

		var oldVote models.CanteenRatingVote
		oldVoteType := ""
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("rating_id = ? AND user_id = ?", ratingID, userID).
			First(&oldVote).Error
		if err == nil {
			oldVoteType = oldVote.VoteType
		} else if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}

		nextVote := input.Vote
		if oldVoteType == input.Vote {
			nextVote = "none"
		}

		helpfulDelta, unhelpfulDelta := ratingVoteDeltas(oldVoteType, nextVote)

		if nextVote == "none" {
			if oldVoteType != "" {
				if err := tx.Delete(&oldVote).Error; err != nil {
					return err
				}
			}
			myVote = ""
		} else if oldVoteType == "" {
			if err := tx.Create(&models.CanteenRatingVote{
				RatingID: ratingID,
				UserID:   userID,
				VoteType: nextVote,
			}).Error; err != nil {
				return err
			}
			myVote = nextVote
		} else {
			if err := tx.Model(&oldVote).Update("vote_type", nextVote).Error; err != nil {
				return err
			}
			myVote = nextVote
		}

		updates := map[string]interface{}{}
		if helpfulDelta != 0 {
			updates["helpful_count"] = nonNegativeCountExpr(tx, "helpful_count", helpfulDelta)
		}
		if unhelpfulDelta != 0 {
			updates["unhelpful_count"] = nonNegativeCountExpr(tx, "unhelpful_count", unhelpfulDelta)
		}
		if len(updates) > 0 {
			if err := tx.Model(&models.CanteenRating{}).Where("id = ?", ratingID).UpdateColumns(updates).Error; err != nil {
				return err
			}
		}

		return tx.First(&updated, ratingID).Error
	})

	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "评价不存在"})
		case errors.Is(err, errVoteOwnRating):
			c.JSON(http.StatusBadRequest, gin.H{"error": "不能给自己的评价投票"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "投票失败"})
		}
		return
	}

	var voteValue interface{}
	if myVote != "" {
		voteValue = myVote
	}
	c.JSON(http.StatusOK, gin.H{
		"message":         "操作成功",
		"rating_id":       updated.ID,
		"helpful_count":   updated.HelpfulCount,
		"unhelpful_count": updated.UnhelpfulCount,
		"my_vote":         voteValue,
	})
}

var errVoteOwnRating = errors.New("cannot vote on own rating")

func ratingVoteDeltas(oldVote, nextVote string) (int, int) {
	helpfulDelta := 0
	unhelpfulDelta := 0
	if oldVote == "up" {
		helpfulDelta--
	} else if oldVote == "down" {
		unhelpfulDelta--
	}
	if nextVote == "up" {
		helpfulDelta++
	} else if nextVote == "down" {
		unhelpfulDelta++
	}
	return helpfulDelta, unhelpfulDelta
}

func nonNegativeCountExpr(db *gorm.DB, column string, delta int) clause.Expr {
	if db.Dialector.Name() == "sqlite" {
		return gorm.Expr("CASE WHEN "+column+" + ? < 0 THEN 0 ELSE "+column+" + ? END", delta, delta)
	}
	return gorm.Expr("GREATEST("+column+" + ?, 0)", delta)
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
