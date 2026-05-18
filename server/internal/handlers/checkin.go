package handlers

import (
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// CheckInHandler 签到处理器
type CheckInHandler struct {
	db *gorm.DB
}

// NewCheckInHandler 创建签到处理器
func NewCheckInHandler(db *gorm.DB) *CheckInHandler {
	return &CheckInHandler{db: db}
}

// calcExpReward 根据连续签到天数计算经验奖励
func calcExpReward(streak int) int {
	if streak >= 30 {
		return 15
	}
	if streak >= 10 {
		return 10
	}
	if streak >= 3 {
		return 3
	}
	return 1
}

// DoCheckIn 执行签到
func (h *CheckInHandler) DoCheckIn(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	today := time.Now().Format("2006-01-02")
	yesterday := time.Now().AddDate(0, 0, -1).Format("2006-01-02")

	// 检查今天是否已签到
	var existing models.CheckIn
	if err := h.db.Where("user_id = ? AND check_in_date = ?", uid, today).First(&existing).Error; err == nil {
		c.JSON(http.StatusOK, gin.H{
			"already":     true,
			"streak_days": existing.StreakDays,
			"exp_earned":  existing.ExpEarned,
			"message":     "今天已经签过到了",
		})
		return
	}

	// 查询昨天的签到记录以计算连续天数
	var yesterdayRecord models.CheckIn
	streakDays := 1
	if err := h.db.Where("user_id = ? AND check_in_date = ?", uid, yesterday).First(&yesterdayRecord).Error; err == nil {
		streakDays = yesterdayRecord.StreakDays + 1
	}

	expEarned := calcExpReward(streakDays)

	// 创建签到记录
	record := models.CheckIn{
		UserID:      uid,
		CheckInDate: today,
		StreakDays:   streakDays,
		ExpEarned:   expEarned,
	}
	if err := h.db.Create(&record).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "签到失败"})
		return
	}

	// 更新用户经验
	h.db.Model(&models.User{}).Where("id = ?", uid).Update("exp", gorm.Expr("exp + ?", expEarned))

	// 查询用户最新经验
	var user models.User
	h.db.Select("exp").First(&user, uid)

	c.JSON(http.StatusOK, gin.H{
		"already":     false,
		"streak_days": streakDays,
		"exp_earned":  expEarned,
		"total_exp":   user.Exp,
		"message":     "签到成功",
	})
}

// GetStatus 获取签到状态
func (h *CheckInHandler) GetStatus(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	today := time.Now().Format("2006-01-02")

	var todayRecord models.CheckIn
	checkedIn := false
	streakDays := 0

	if err := h.db.Where("user_id = ? AND check_in_date = ?", uid, today).First(&todayRecord).Error; err == nil {
		checkedIn = true
		streakDays = todayRecord.StreakDays
	} else {
		// 没签到，查昨天记录看连续天数
		yesterday := time.Now().AddDate(0, 0, -1).Format("2006-01-02")
		var yesterdayRecord models.CheckIn
		if err := h.db.Where("user_id = ? AND check_in_date = ?", uid, yesterday).First(&yesterdayRecord).Error; err == nil {
			streakDays = yesterdayRecord.StreakDays
		}
	}

	var user models.User
	h.db.Select("exp").First(&user, uid)

	// 计算下次签到可获得的经验
	nextStreak := streakDays + 1
	if checkedIn {
		nextStreak = streakDays + 1
	}
	_ = strconv.Itoa(nextStreak) // suppress unused

	c.JSON(http.StatusOK, gin.H{
		"checked_in":  checkedIn,
		"streak_days": streakDays,
		"total_exp":   user.Exp,
		"next_exp":    calcExpReward(nextStreak),
	})
}
