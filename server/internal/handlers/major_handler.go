package handlers

import (
	"net/http"
	"strconv"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

var majorLogDB *gorm.DB

func SetMajorLogDB(db *gorm.DB) { majorLogDB = db }

func logMajorAdmin(c *gin.Context, action, target string) {
	if majorLogDB == nil {
		return
	}
	uid, _ := c.Get("user_id")
	var u models.User
	if err := majorLogDB.Select("nickname").First(&u, uid).Error; err != nil {
		u.Nickname = "Unknown Admin"
	}
	majorLogDB.Create(&models.AdminLog{AdminID: uid.(uint), AdminName: u.Nickname, Action: action, Target: target})
	// 管理员操作经验+1
	majorLogDB.Model(&models.User{}).Where("id = ?", uid).UpdateColumn("admin_exp", gorm.Expr("COALESCE(admin_exp, 0) + 1"))
}

type MajorHandler struct {
	db *gorm.DB
}

func NewMajorHandler(db *gorm.DB) *MajorHandler {
	return &MajorHandler{db: db}
}

func (h *MajorHandler) GetList(c *gin.Context) {
	type MajorWithStats struct {
		models.Major
		RatingCount int     `json:"rating_count"`
		AverageStar float64 `json:"average_star"`
	}
	var result []MajorWithStats

	// 修复 N+1 查询
	err := h.db.Table("majors").
		Select("majors.*, COUNT(major_ratings.id) as rating_count, COALESCE(AVG(CAST(major_ratings.star AS FLOAT)), 0) as average_star").
		Joins("LEFT JOIN major_ratings ON major_ratings.major_id = majors.id AND major_ratings.status = 'normal' AND major_ratings.deleted_at IS NULL").
		Where("majors.verified = ?", true).
		Group("majors.id").
		Order("average_star DESC, rating_count DESC, majors.created_at DESC").
		Find(&result).Error

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取专业列表失败"})
		return
	}

	c.JSON(http.StatusOK, result)
}

func (h *MajorHandler) GetDetail(c *gin.Context) {
	id, _ := strconv.ParseUint(c.Param("id"), 10, 64)
	var major models.Major
	if err := h.db.First(&major, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "专业不存在"})
		return
	}
	sortMode := c.Query("review_sort")
	var ratings []models.MajorRating
	query := h.db.Where("major_id = ? AND status = 'normal' AND deleted_at IS NULL", id).Preload("User")

	if sortMode == "best" {
		query = query.Order("(helpful_count - unhelpful_count * 2) DESC, CASE WHEN TRIM(comment) <> '' THEN 1 ELSE 0 END DESC, helpful_count DESC, created_at DESC")
	} else {
		query = query.Order("created_at DESC")
	}

	if err := query.Find(&ratings).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取评价列表失败"})
		return
	}
	var ratingDTOs []map[string]interface{}
	for _, r := range ratings {
		userName := ""
		userAvatar := ""
		if r.User != nil {
			userName = r.User.Nickname
			userAvatar = r.User.Avatar
		}

		isOwn := false
		if userID, exists := c.Get("user_id"); exists {
			isOwn = r.UserID == userID.(uint)
		}

		ratingDTOs = append(ratingDTOs, map[string]interface{}{
			"id":              r.ID,
			"major_id":        r.MajorID,
			"user_id":         r.UserID,
			"star":            r.Star,
			"comment":         r.Comment,
			"user_name":       userName,
			"user_avatar":     userAvatar,
			"created_at":      r.CreatedAt,
			"updated_at":      r.UpdatedAt,
			"helpful_count":   r.HelpfulCount,
			"unhelpful_count": r.UnhelpfulCount,
			"my_vote":         r.MyVote,
			"is_own":          isOwn,
		})
	}
	var count int64
	var avg float64
	h.db.Model(&models.MajorRating{}).Where("major_id = ? AND status = 'normal' AND deleted_at IS NULL", id).Count(&count)
	if count > 0 {
		h.db.Model(&models.MajorRating{}).Where("major_id = ? AND status = 'normal' AND deleted_at IS NULL", id).Select("AVG(CAST(star AS FLOAT))").Scan(&avg)
	}
	var myRating *models.MajorRating
	if userID, exists := c.Get("user_id"); exists {
		var rating models.MajorRating
		if err := h.db.Where("major_id = ? AND user_id = ? AND deleted_at IS NULL", id, userID).First(&rating).Error; err == nil {
			myRating = &rating
		}
	}
	c.JSON(http.StatusOK, gin.H{
		"major": major, "ratings": ratingDTOs, "rating_count": count, "average_star": avg, "my_rating": myRating,
	})
}

func (h *MajorHandler) Create(c *gin.Context) {
	userID, _ := c.Get("user_id")
	role, _ := c.Get("role")
	var input struct {
		Name  string `json:"name" binding:"required"`
		Level string `json:"level" binding:"required"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	var existing models.Major
	if err := h.db.Where("name = ? AND level = ?", input.Name, input.Level).First(&existing).Error; err == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该专业已存在"})
		return
	}

	verified := role == "admin" || role == "super_admin"
	major := models.Major{Name: input.Name, Level: input.Level, Verified: verified, CreatedBy: userID.(uint)}
	if err := h.db.Create(&major).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "添加失败"})
		return
	}
	if verified {
		c.JSON(http.StatusCreated, major)
	} else {
		c.JSON(http.StatusCreated, gin.H{"message": "已提交，等待审核", "major": major})
	}
}

func (h *MajorHandler) Rate(c *gin.Context) {
	userID, _ := c.Get("user_id")
	mid, _ := strconv.ParseUint(c.Param("id"), 10, 64)
	var input struct {
		Star    int    `json:"star" binding:"required,min=1,max=5"`
		Comment string `json:"comment" binding:"max=500"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	var major models.Major
	if h.db.First(&major, mid).Error != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "专业不存在"})
		return
	}
	var rating models.MajorRating
	err := h.db.Where("major_id = ? AND user_id = ?", mid, userID).First(&rating).Error
	if err == nil {
		h.db.Model(&rating).Updates(map[string]interface{}{"star": input.Star, "comment": input.Comment})
		c.JSON(http.StatusOK, gin.H{"message": "评价已更新"})
	} else {
		rating = models.MajorRating{MajorID: uint(mid), UserID: userID.(uint), Star: input.Star, Comment: input.Comment}
		if err := h.db.Create(&rating).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
			return
		}
		c.JSON(http.StatusCreated, gin.H{"message": "评价成功"})
	}
}

// VoteRating 给专业评价投票
func (h *MajorHandler) VoteRating(c *gin.Context) {
	userID, _ := c.Get("user_id")
	ratingID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的评价ID"})
		return
	}
	var input struct {
		Vote string `json:"vote" binding:"required"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	result, err := services.ToggleRatingVote(h.db, "major", uint(ratingID), userID.(uint), input.Vote)
	if err != nil {
		if err.Error() == "不能给自己的评价投票" || err.Error() == "无法对该状态的评价进行投票" || err.Error() == "评价不存在或已删除" {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "投票失败"})
		}
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"rating_id":       ratingID,
		"helpful_count":   result.HelpfulCount,
		"unhelpful_count": result.UnhelpfulCount,
		"my_vote":         result.MyVote,
	})
}

// DeleteRating 删除自己的专业评价
func (h *MajorHandler) DeleteRating(c *gin.Context) {
	userID, _ := c.Get("user_id")
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}

	result := h.db.Where("id = ? AND user_id = ?", id, userID).Delete(&models.MajorRating{})
	if result.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	if result.RowsAffected == 0 {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权删除"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "已删除"})
}

func (h *MajorHandler) Verify(c *gin.Context) {
	id, _ := strconv.Atoi(c.Param("id"))
	var m models.Major
	if err := h.db.First(&m, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "找不到该专业"})
		return
	}

	if err := h.db.Model(&m).Update("verified", true).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	logMajorAdmin(c, "审核通过专业", m.Name)
	c.JSON(http.StatusOK, gin.H{"message": "已审核通过"})
}

func (h *MajorHandler) Reject(c *gin.Context) {
	id, _ := strconv.Atoi(c.Param("id"))
	var m models.Major
	if err := h.db.First(&m, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "找不到该专业"})
		return
	}

	if err := h.db.Delete(&models.Major{}, id).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	logMajorAdmin(c, "拒绝专业", m.Name)
	c.JSON(http.StatusOK, gin.H{"message": "已拒绝"})
}

func (h *MajorHandler) DeleteMajor(c *gin.Context) {
	id, _ := strconv.Atoi(c.Param("id"))
	var m models.Major
	if err := h.db.First(&m, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "专业不存在"})
		return
	}
	h.db.Where("major_id = ?", id).Delete(&models.MajorRating{})
	if err := h.db.Delete(&models.Major{}, id).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	logMajorAdmin(c, "删除专业", m.Name)
	c.JSON(http.StatusOK, gin.H{"message": "已删除"})
}

func (h *MajorHandler) GetPending(c *gin.Context) {
	var majors []models.Major
	if err := h.db.Where("verified = ?", false).Order("created_at DESC").Find(&majors).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取待审核专业失败"})
		return
	}
	c.JSON(http.StatusOK, majors)
}
