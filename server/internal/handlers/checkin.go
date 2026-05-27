package handlers

import (
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
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

// DoCheckIn 执行签到 (事务 + 行锁，高并发原子化防御)
func (h *CheckInHandler) DoCheckIn(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	// 统一时区锚点：强制使用 Asia/Shanghai
	loc, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "系统时区配置错误"})
		return
	}
	now := time.Now().In(loc)
	todayStr := now.Format("2006-01-02")
	yesterdayStr := now.AddDate(0, 0, -1).Format("2006-01-02")

	// 开启事务
	tx := h.db.Begin()
	if tx.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "开启事务失败"})
		return
	}
	defer func() {
		if r := recover(); r != nil {
			tx.Rollback()
		}
	}()

	// 查用户并加行锁 (FOR UPDATE)，防止极限并发下同一用户多个请求进入计算逻辑
	var user models.User
	if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ?", uid).First(&user).Error; err != nil {
		tx.Rollback()
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取用户状态失败"})
		return
	}

	// 校验今天是否已签到
	if user.LastCheckInDate == todayStr {
		tx.Rollback()
		c.JSON(http.StatusBadRequest, gin.H{"error": "您今天已经签过到了，明天再来吧！"})
		return
	}

	// 计算连续签到天数 (Streak)
	streak := 1
	var yesterdayRecord models.CheckIn
	if err := tx.Where("user_id = ? AND check_in_date = ?", uid, yesterdayStr).First(&yesterdayRecord).Error; err == nil {
		streak = yesterdayRecord.StreakDays + 1
	}

	// 调用之前被闲置的函数，动态计算经验值奖励
	expEarned := calcExpReward(streak)

	// 写入 check_ins 历史表
	newCheckIn := models.CheckIn{
		UserID:      uid,
		CheckInDate: todayStr,
		StreakDays:  streak,
		ExpEarned:   expEarned,
	}
	if err := tx.Create(&newCheckIn).Error; err != nil {
		tx.Rollback()
		c.JSON(http.StatusInternalServerError, gin.H{"error": "记录签到详情失败"})
		return
	}

	// 同步更新 users 表的主状态
	if err := tx.Model(&user).Updates(map[string]interface{}{
		"credits":            gorm.Expr("credits + ?", 3),
		"exp":                gorm.Expr("exp + ?", expEarned),
		"last_check_in_date": todayStr,
	}).Error; err != nil {
		tx.Rollback()
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新用户资产失败"})
		return
	}

	// 提交事务
	if err := tx.Commit().Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "提交事务失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"success":        true,
		"message":        fmt.Sprintf("签到成功！积分+3，经验+%d", expEarned),
		"credits_earned": 3,
		"streak_days":    streak,
		"exp_earned":     expEarned,
	})
}

// GetStatus 获取签到状态
func (h *CheckInHandler) GetStatus(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	loc, _ := time.LoadLocation("Asia/Shanghai")
	now := time.Now().In(loc)
	today := now.Format("2006-01-02")

	var user models.User
	h.db.Select("exp, last_check_in_date").First(&user, uid)

	checkedIn := user.LastCheckInDate == today
	streakDays := 0

	var todayRecord models.CheckIn
	if err := h.db.Where("user_id = ? AND check_in_date = ?", uid, today).First(&todayRecord).Error; err == nil {
		streakDays = todayRecord.StreakDays
	} else {
		if checkedIn {
			// 旧系统今天签过到，但新表里没有，默认按 1 算
			streakDays = 1
		} else {
			// 没签到，查昨天记录看连续天数
			yesterday := now.AddDate(0, 0, -1).Format("2006-01-02")
			var yesterdayRecord models.CheckIn
			if err := h.db.Where("user_id = ? AND check_in_date = ?", uid, yesterday).First(&yesterdayRecord).Error; err == nil {
				streakDays = yesterdayRecord.StreakDays
			}
		}
	}

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
