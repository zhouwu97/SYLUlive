package services

import (
	"errors"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

// CheckInResult 是普通签到的确定性结果。重复请求会返回 Already=true 且不会再次增加经验。
type CheckInResult struct {
	Already     bool
	StreakDays  int
	ExpEarned   int
	TotalExp    int
	CheckInDate time.Time
}

// CheckInStatus 是面向客户端的签到状态，由事实表和可重建汇总共同生成。
type CheckInStatus struct {
	CheckedIn   bool
	StreakDays  int
	TotalExp    int
	NextExp     int
	CheckInDate time.Time
}

// CheckInService 统一封装签到事实、汇总和经验入账，避免多个 Handler 各自维护状态。
type CheckInService struct {
	db *gorm.DB
}

func NewCheckInService(db *gorm.DB) *CheckInService {
	return &CheckInService{db: db}
}

// CheckIn 在指定业务日执行签到。调用方必须传入 Asia/Shanghai 的当前时间。
func (s *CheckInService) CheckIn(userID uint, now time.Time) (CheckInResult, error) {
	today := checkInDateOnly(now)
	yesterday := today.AddDate(0, 0, -1)
	result := CheckInResult{CheckInDate: today}
	err := s.db.Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, userID).Error; err != nil {
			return err
		}

		var existing models.CheckIn
		err := tx.Where("user_id = ? AND check_in_date = ?", userID, today).First(&existing).Error
		if err == nil {
			result.Already = true
			result.StreakDays = existing.StreakDays
			result.TotalExp = user.Exp
			return nil
		}
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}

		streak := 1
		var yesterdayRecord models.CheckIn
		if err := tx.Where("user_id = ? AND check_in_date = ?", userID, yesterday).First(&yesterdayRecord).Error; err == nil {
			streak = yesterdayRecord.StreakDays + 1
		} else if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		expEarned := CheckInExpReward(streak)
		record := models.CheckIn{UserID: userID, CheckInDate: today, StreakDays: streak, ExpEarned: expEarned}
		if err := tx.Create(&record).Error; err != nil {
			return err
		}
		if err := tx.Create(&models.UserExperienceLedger{
			UserID: userID, SourceType: "checkin", SourceID: record.ID, Delta: expEarned, Reason: "每日签到",
		}).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
			"exp":                gorm.Expr("exp + ?", expEarned),
			"last_check_in_date": today.Format("2006-01-02"),
		}).Error; err != nil {
			return err
		}

		if err := upsertCheckInStat(tx, userID, today, streak); err != nil {
			return err
		}
		result.StreakDays = streak
		result.ExpEarned = expEarned
		result.TotalExp = user.Exp + expEarned
		return nil
	})
	return result, err
}

// Status 只以签到事实判断今天是否已签到；汇总缺失时降级查询事实，不会依赖旧 users 字段。
func (s *CheckInService) Status(userID uint, now time.Time) (CheckInStatus, error) {
	today := checkInDateOnly(now)
	status := CheckInStatus{CheckInDate: today}
	var user models.User
	if err := s.db.Select("id", "exp").First(&user, userID).Error; err != nil {
		return status, err
	}
	status.TotalExp = user.Exp
	var todayRecord models.CheckIn
	if err := s.db.Where("user_id = ? AND check_in_date = ?", userID, today).First(&todayRecord).Error; err == nil {
		status.CheckedIn = true
		status.StreakDays = todayRecord.StreakDays
		status.NextExp = CheckInExpReward(todayRecord.StreakDays + 1)
		return status, nil
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return status, err
	}

	var stat models.UserCheckInStat
	if err := s.db.Where("user_id = ?", userID).First(&stat).Error; err == nil && stat.LastCheckInDate != nil && sameCheckInDay(*stat.LastCheckInDate, today.AddDate(0, 0, -1)) {
		status.StreakDays = stat.CurrentStreak
	} else if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
		return status, err
	}
	status.NextExp = CheckInExpReward(status.StreakDays + 1)
	return status, nil
}

// RebuildUserStats 从事实表重建单个用户的汇总，供修复任务和运维接口调用。
func (s *CheckInService) RebuildUserStats(userID uint) (models.UserCheckInStat, error) {
	return models.RebuildUserCheckInStats(s.db, userID)
}

// CheckInExpReward 根据连续签到天数计算经验奖励。
func CheckInExpReward(streak int) int {
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

func upsertCheckInStat(tx *gorm.DB, userID uint, date time.Time, currentStreak int) error {
	var stat models.UserCheckInStat
	err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("user_id = ?", userID).First(&stat).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return tx.Create(&models.UserCheckInStat{
			UserID: userID, LastCheckInDate: &date, CurrentStreak: currentStreak, LongestStreak: currentStreak,
		}).Error
	}
	if err != nil {
		return err
	}
	longest := stat.LongestStreak
	if currentStreak > longest {
		longest = currentStreak
	}
	return tx.Model(&models.UserCheckInStat{}).Where("user_id = ?", userID).Updates(map[string]interface{}{
		"last_check_in_date": date,
		"current_streak":     currentStreak,
		"longest_streak":     longest,
	}).Error
}

func checkInDateOnly(value time.Time) time.Time {
	return time.Date(value.Year(), value.Month(), value.Day(), 0, 0, 0, 0, time.UTC)
}

func sameCheckInDay(left, right time.Time) bool {
	return left.Format("2006-01-02") == right.Format("2006-01-02")
}

// FormatCheckInDate 把 date-only 字段序列化为稳定的 YYYY-MM-DD，而非 RFC3339 时间戳。
func FormatCheckInDate(value time.Time) string {
	return value.Format("2006-01-02")
}
