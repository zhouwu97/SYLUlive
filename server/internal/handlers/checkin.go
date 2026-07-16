package handlers

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// CheckInHandler 签到接口处理器。
type CheckInHandler struct {
	db      *gorm.DB
	service *services.CheckInService
}

// NewCheckInHandler 创建签到处理器。
func NewCheckInHandler(db *gorm.DB) *CheckInHandler {
	return &CheckInHandler{db: db, service: services.NewCheckInService(db)}
}

// DoCheckIn 执行签到。重复请求返回 200，使客户端重试和双击天然幂等。
func (h *CheckInHandler) DoCheckIn(c *gin.Context) {
	uid := c.GetUint("user_id")
	now, err := shanghaiNow()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "系统时区配置错误"})
		return
	}
	result, err := h.service.CheckIn(uid, now)
	if err != nil {
		writeCheckInError(c, err, "签到失败")
		return
	}
	message := fmt.Sprintf("签到成功！经验+%d", result.ExpEarned)
	if result.Already {
		message = "今天已经签过到了"
	}
	c.JSON(http.StatusOK, gin.H{
		"success":       true,
		"already":       result.Already,
		"message":       message,
		"check_in_date": services.FormatCheckInDate(result.CheckInDate),
		"streak_days":   result.StreakDays,
		"exp_earned":    result.ExpEarned,
		"total_exp":     result.TotalExp,
	})
}

// GetStatus 获取签到状态。是否已签到只查询当天事实记录。
func (h *CheckInHandler) GetStatus(c *gin.Context) {
	uid := c.GetUint("user_id")
	now, err := shanghaiNow()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "系统时区配置错误"})
		return
	}
	status, err := h.service.Status(uid, now)
	if err != nil {
		writeCheckInError(c, err, "获取签到状态失败")
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"checked_in":    status.CheckedIn,
		"check_in_date": services.FormatCheckInDate(status.CheckInDate),
		"streak_days":   status.StreakDays,
		"total_exp":     status.TotalExp,
		"next_exp":      status.NextExp,
	})
}

// RebuildUserStats 根据签到事实重建指定用户的汇总，只允许超级管理员调用。
func (h *CheckInHandler) RebuildUserStats(c *gin.Context) {
	userID64, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || userID64 == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})
		return
	}
	userID := uint(userID64)
	var user models.User
	if err := h.db.Select("id").First(&user, userID).Error; err != nil {
		writeCheckInError(c, err, "读取用户失败")
		return
	}
	var previous models.UserCheckInStat
	_ = h.db.Where("user_id = ?", userID).First(&previous).Error
	rebuilt, err := h.service.RebuildUserStats(userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "重建签到汇总失败"})
		return
	}
	operatorID := c.GetUint("user_id")
	if err := h.db.Create(&models.CheckInRepairLog{
		UserID: userID, OperatorID: operatorID, Action: "rebuild_stats", Reason: "管理员发起签到汇总回算",
		PreviousStreak: previous.CurrentStreak, NewStreak: rebuilt.CurrentStreak,
	}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "写入签到修复审计日志失败"})
		return
	}
	lastDate := ""
	if rebuilt.LastCheckInDate != nil {
		lastDate = services.FormatCheckInDate(*rebuilt.LastCheckInDate)
	}
	c.JSON(http.StatusOK, gin.H{
		"success":            true,
		"user_id":            userID,
		"last_check_in_date": lastDate,
		"current_streak":     rebuilt.CurrentStreak,
		"longest_streak":     rebuilt.LongestStreak,
	})
}

func shanghaiNow() (time.Time, error) {
	loc, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		return time.Time{}, err
	}
	return time.Now().In(loc), nil
}

func writeCheckInError(c *gin.Context, err error, fallback string) {
	if errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	c.JSON(http.StatusInternalServerError, gin.H{"error": fallback})
}
