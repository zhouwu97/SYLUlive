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

// DoCheckIn 执行签到 (高并发原子化防御)
func (h *CheckInHandler) DoCheckIn(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	loc, _ := time.LoadLocation("Asia/Shanghai")
	todayStr := time.Now().In(loc).Format("2006-01-02")

	// 核心原子化 SQL：只有当 last_check_in_date 不等于今天（或者为 NULL，对于空字符串是 =""）时，才允许更新
	// 这里同时处理了 "" 和 正常的日期对比
	result := h.db.Exec(`
		UPDATE users 
		SET credits = credits + 3, 
			exp = exp + 10, 
			last_check_in_date = ? 
		WHERE id = ? AND (last_check_in_date IS NULL OR last_check_in_date = '' OR last_check_in_date != ?)
	`, todayStr, uid, todayStr)

	if result.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "签到失败，数据库异常"})
		return
	}

	// 如果 RowsAffected == 0，说明该用户今天已经签过到，WHERE 条件不成立，直接拦截
	if result.RowsAffected == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "您今天已经签过到了，明天再来吧！"})
		return
	}

	// 签到成功
	c.JSON(http.StatusOK, gin.H{
		"success": true, 
		"message": "签到成功！积分+3，经验+10",
		"credits_earned": 3,
		"exp_earned": 10,
	})
}

// GetStatus 获取签到状态
func (h *CheckInHandler) GetStatus(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	loc, _ := time.LoadLocation("Asia/Shanghai")
	now := time.Now().In(loc)
	today := now.Format("2006-01-02")

	var todayRecord models.CheckIn
	checkedIn := false
	streakDays := 0

	if err := h.db.Where("user_id = ? AND check_in_date = ?", uid, today).First(&todayRecord).Error; err == nil {
		checkedIn = true
		streakDays = todayRecord.StreakDays
	} else {
		// 没签到，查昨天记录看连续天数
		yesterday := now.AddDate(0, 0, -1).Format("2006-01-02")
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
