package handlers

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

var majorLogDB *gorm.DB

func SetMajorLogDB(db *gorm.DB) { majorLogDB = db }

func logMajorAdmin(c *gin.Context, action, target string) {
	if majorLogDB == nil {
		return
	}
	uid, _ := c.Get("user_id")
	var u models.User
	majorLogDB.Select("nickname").First(&u, uid)
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
	var majors []models.Major
	if err := h.db.Where("verified = ?", true).Order("created_at DESC").Find(&majors).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取专业列表失败"})
		return
	}

	type MajorWithStats struct {
		models.Major
		RatingCount int     `json:"rating_count"`
		AverageStar float64 `json:"average_star"`
	}
	result := make([]MajorWithStats, 0, len(majors))
	for _, m := range majors {
		var count int64
		var avg float64
		h.db.Model(&models.MajorRating{}).Where("major_id = ?", m.ID).Count(&count)
		if count > 0 {
			h.db.Model(&models.MajorRating{}).Where("major_id = ?", m.ID).Select("AVG(CAST(star AS FLOAT))").Scan(&avg)
		}
		item := MajorWithStats{Major: m, RatingCount: int(count), AverageStar: avg}
		result = append(result, item)
	}
	// 按平均分从高到低排序
	for i := 0; i < len(result); i++ {
		for j := i + 1; j < len(result); j++ {
			if result[j].AverageStar > result[i].AverageStar {
				result[i], result[j] = result[j], result[i]
			}
		}
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
	var ratings []models.MajorRating
	h.db.Where("major_id = ?", id).Order("created_at DESC").Find(&ratings)
	for i := range ratings {
		var user models.User
		if err := h.db.Select("nickname, student_id").First(&user, ratings[i].UserID).Error; err == nil {
			ratings[i].UserName = user.Nickname
			ratings[i].UserStudentID = user.StudentID
		}
	}
	var count int64
	var avg float64
	h.db.Model(&models.MajorRating{}).Where("major_id = ?", id).Count(&count)
	if count > 0 {
		h.db.Model(&models.MajorRating{}).Where("major_id = ?", id).Select("AVG(CAST(star AS FLOAT))").Scan(&avg)
	}
	var myRating *models.MajorRating
	if userID, exists := c.Get("user_id"); exists {
		var rating models.MajorRating
		if err := h.db.Where("major_id = ? AND user_id = ?", id, userID).First(&rating).Error; err == nil {
			myRating = &rating
		}
	}
	c.JSON(http.StatusOK, gin.H{
		"major": major, "ratings": ratings, "rating_count": count, "average_star": avg, "my_rating": myRating,
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
		h.db.Create(&rating)
		c.JSON(http.StatusCreated, gin.H{"message": "评价成功"})
	}
}

func (h *MajorHandler) Verify(c *gin.Context) {
	id, _ := strconv.Atoi(c.Param("id"))
	h.db.Model(&models.Major{}).Where("id = ?", id).Update("verified", true)
	var m models.Major
	h.db.First(&m, id)
	logMajorAdmin(c, "审核通过专业", m.Name)
	c.JSON(http.StatusOK, gin.H{"message": "已审核通过"})
}

func (h *MajorHandler) Reject(c *gin.Context) {
	id, _ := strconv.Atoi(c.Param("id"))
	var m models.Major
	h.db.First(&m, id)
	h.db.Delete(&models.Major{}, id)
	logMajorAdmin(c, "拒绝专业", m.Name)
	c.JSON(http.StatusOK, gin.H{"message": "已拒绝"})
}

func (h *MajorHandler) GetPending(c *gin.Context) {
	var majors []models.Major
	if err := h.db.Where("verified = ?", false).Order("created_at DESC").Find(&majors).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取待审核专业失败"})
		return
	}
	c.JSON(http.StatusOK, majors)
}
