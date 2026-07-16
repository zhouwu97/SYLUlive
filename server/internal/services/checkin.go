package services

import (
	"errors"
	"fmt"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

// CheckInResult 是普通签到的确定性结果。重复请求会返回 Already=true 且不会再次增加经验。
type CheckInResult struct {
	Already            bool
	StreakDays         int
	ExpEarned          int
	TotalExp           int
	CheckInDate        time.Time
	MakeupCards        int
	MakeupCardsAwarded int
}

// CheckInStatus 是面向客户端的签到状态，由事实表和可重建汇总共同生成。
type CheckInStatus struct {
	CheckedIn   bool
	StreakDays  int
	TotalExp    int
	NextExp     int
	CheckInDate time.Time
	MakeupCards int
}

// CheckInCalendarRecord 是月历中的一条签到事实。
type CheckInCalendarRecord struct {
	CheckInDate time.Time
	StreakDays  int
	ExpEarned   int
	IsMakeup    bool
}

// MakeupCheckInResult 是补签及其历史连续天数、经验修正后的确定性结果。
type MakeupCheckInResult struct {
	Already            bool
	CheckInDate        time.Time
	StreakDays         int
	CheckInExp         int
	ExpEarned          int
	TotalExp           int
	MakeupCards        int
	MakeupCardsAwarded int
}

var (
	ErrNoMakeupCards        = errors.New("补签卡数量不足")
	ErrMakeupDateNotAllowed = errors.New("只能补签本月今天之前的未签到日期")
)

// CheckInCalendar 是指定月份的签到记录和历史汇总。
type CheckInCalendar struct {
	Month         time.Time
	LongestStreak int
	Records       []CheckInCalendarRecord
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
			var stat models.UserCheckInStat
			if statErr := tx.Where("user_id = ?", userID).First(&stat).Error; statErr == nil {
				result.MakeupCards = availableMakeupCards(stat)
			} else if !errors.Is(statErr, gorm.ErrRecordNotFound) {
				return statErr
			}
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

		stat, err := upsertCheckInStat(tx, userID, today, streak)
		if err != nil {
			return err
		}
		if streak%30 == 0 {
			stat.MakeupCardsEarned++
			if err := tx.Model(&models.UserCheckInStat{}).Where("user_id = ?", userID).
				Update("makeup_cards_earned", stat.MakeupCardsEarned).Error; err != nil {
				return err
			}
			result.MakeupCardsAwarded = 1
		}
		result.StreakDays = streak
		result.ExpEarned = expEarned
		result.TotalExp = user.Exp + expEarned
		result.MakeupCards = availableMakeupCards(stat)
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
	var stat models.UserCheckInStat
	statErr := s.db.Where("user_id = ?", userID).First(&stat).Error
	if statErr == nil {
		status.MakeupCards = availableMakeupCards(stat)
	} else if !errors.Is(statErr, gorm.ErrRecordNotFound) {
		return status, statErr
	}
	var todayRecord models.CheckIn
	if err := s.db.Where("user_id = ? AND check_in_date = ?", userID, today).First(&todayRecord).Error; err == nil {
		status.CheckedIn = true
		status.StreakDays = todayRecord.StreakDays
		status.NextExp = CheckInExpReward(todayRecord.StreakDays + 1)
		return status, nil
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return status, err
	}

	if statErr == nil && stat.LastCheckInDate != nil && sameCheckInDay(*stat.LastCheckInDate, today.AddDate(0, 0, -1)) {
		status.StreakDays = stat.CurrentStreak
	}
	status.NextExp = CheckInExpReward(status.StreakDays + 1)
	return status, nil
}

// Calendar 查询指定自然月的签到事实，查询范围始终限制在一个月内。
func (s *CheckInService) Calendar(userID uint, month time.Time) (CheckInCalendar, error) {
	monthStart := time.Date(month.Year(), month.Month(), 1, 0, 0, 0, 0, time.UTC)
	result := CheckInCalendar{
		Month:   monthStart,
		Records: make([]CheckInCalendarRecord, 0),
	}

	var user models.User
	if err := s.db.Select("id").First(&user, userID).Error; err != nil {
		return result, err
	}

	var records []models.CheckIn
	if err := s.db.
		Where("user_id = ? AND check_in_date >= ? AND check_in_date < ?", userID, monthStart, monthStart.AddDate(0, 1, 0)).
		Order("check_in_date ASC").
		Find(&records).Error; err != nil {
		return result, err
	}
	for _, record := range records {
		result.Records = append(result.Records, CheckInCalendarRecord{
			CheckInDate: record.CheckInDate,
			StreakDays:  record.StreakDays,
			ExpEarned:   record.ExpEarned,
			IsMakeup:    record.IsMakeup,
		})
	}

	var stat models.UserCheckInStat
	if err := s.db.Select("longest_streak").Where("user_id = ?", userID).First(&stat).Error; err == nil {
		result.LongestStreak = stat.LongestStreak
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return result, err
	}
	return result, nil
}

// Makeup 使用一张补签卡补录本月过去的某一天，并重算受影响的签到经验。
func (s *CheckInService) Makeup(userID uint, targetDate, now time.Time) (MakeupCheckInResult, error) {
	targetDate = checkInDateOnly(targetDate)
	today := checkInDateOnly(now)
	result := MakeupCheckInResult{CheckInDate: targetDate}
	if !targetDate.Before(today) || targetDate.Year() != today.Year() || targetDate.Month() != today.Month() {
		return result, ErrMakeupDateNotAllowed
	}

	err := s.db.Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, userID).Error; err != nil {
			return err
		}

		var existing models.CheckIn
		if err := tx.Where("user_id = ? AND check_in_date = ?", userID, targetDate).First(&existing).Error; err == nil {
			result.Already = true
			result.StreakDays = existing.StreakDays
			result.CheckInExp = existing.ExpEarned
			result.TotalExp = user.Exp
			var stat models.UserCheckInStat
			if statErr := tx.Where("user_id = ?", userID).First(&stat).Error; statErr == nil {
				result.MakeupCards = availableMakeupCards(stat)
			} else if !errors.Is(statErr, gorm.ErrRecordNotFound) {
				return statErr
			}
			return nil
		} else if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}

		var previousStat models.UserCheckInStat
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("user_id = ?", userID).First(&previousStat).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return ErrNoMakeupCards
			}
			return err
		}
		if availableMakeupCards(previousStat) == 0 {
			return ErrNoMakeupCards
		}

		makeupRecord := models.CheckIn{
			UserID: userID, CheckInDate: targetDate, StreakDays: 1, ExpEarned: 1, IsMakeup: true,
		}
		if err := tx.Create(&makeupRecord).Error; err != nil {
			return err
		}

		var records []models.CheckIn
		if err := tx.Where("user_id = ?", userID).Order("check_in_date ASC, id ASC").Find(&records).Error; err != nil {
			return err
		}
		var ledgers []models.UserExperienceLedger
		if err := tx.Where("user_id = ? AND source_type = ?", userID, "checkin").Find(&ledgers).Error; err != nil {
			return err
		}
		ledgerByCheckIn := make(map[uint]models.UserExperienceLedger, len(ledgers))
		for _, ledger := range ledgers {
			ledgerByCheckIn[ledger.SourceID] = ledger
		}

		current, longest := 0, 0
		makeupCardsEarned, makeupCardsUsed := 0, 0
		expDelta := 0
		var previousDate time.Time
		for index := range records {
			record := &records[index]
			if index == 0 || !sameCheckInDay(record.CheckInDate, previousDate.AddDate(0, 0, 1)) {
				current = 1
			} else {
				current++
			}
			if current > longest {
				longest = current
			}
			if current%30 == 0 {
				makeupCardsEarned++
			}
			if record.IsMakeup {
				makeupCardsUsed++
			}

			updates := map[string]interface{}{"streak_days": current}
			expectedExp := CheckInExpReward(current)
			ledger, hasLedger := ledgerByCheckIn[record.ID]
			if record.ID == makeupRecord.ID {
				expDelta += expectedExp
				updates["exp_earned"] = expectedExp
				if err := tx.Create(&models.UserExperienceLedger{
					UserID: userID, SourceType: "checkin", SourceID: record.ID, Delta: expectedExp,
					Reason: fmt.Sprintf("补签：%s", FormatCheckInDate(targetDate)),
				}).Error; err != nil {
					return err
				}
				result.StreakDays = current
				result.CheckInExp = expectedExp
			} else if hasLedger {
				expDelta += expectedExp - ledger.Delta
				updates["exp_earned"] = expectedExp
				if ledger.Delta != expectedExp {
					if err := tx.Model(&models.UserExperienceLedger{}).Where("id = ?", ledger.ID).
						Update("delta", expectedExp).Error; err != nil {
						return err
					}
				}
			}
			if err := tx.Model(&models.CheckIn{}).Where("id = ?", record.ID).Updates(updates).Error; err != nil {
				return err
			}
			previousDate = record.CheckInDate
		}

		if makeupCardsEarned < previousStat.MakeupCardsEarned {
			return errors.New("补签卡统计异常")
		}
		result.MakeupCardsAwarded = makeupCardsEarned - previousStat.MakeupCardsEarned
		result.MakeupCards = availableMakeupCards(models.UserCheckInStat{
			MakeupCardsEarned:  makeupCardsEarned,
			MakeupCardsGranted: previousStat.MakeupCardsGranted,
			MakeupCardsUsed:    makeupCardsUsed,
		})
		result.ExpEarned = expDelta
		result.TotalExp = user.Exp + expDelta
		lastDate := checkInDateOnly(previousDate)
		if err := tx.Model(&models.UserCheckInStat{}).Where("user_id = ?", userID).Updates(map[string]interface{}{
			"last_check_in_date":  lastDate,
			"current_streak":      current,
			"longest_streak":      longest,
			"makeup_cards_earned": makeupCardsEarned,
			"makeup_cards_used":   makeupCardsUsed,
		}).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
			"exp":                gorm.Expr("exp + ?", expDelta),
			"last_check_in_date": lastDate.Format("2006-01-02"),
		}).Error; err != nil {
			return err
		}
		return tx.Create(&models.CheckInRepairLog{
			UserID: userID, OperatorID: userID, Action: "user_makeup",
			Reason:         fmt.Sprintf("用户使用补签卡补签 %s", FormatCheckInDate(targetDate)),
			PreviousStreak: previousStat.CurrentStreak, NewStreak: current, ExpDelta: expDelta,
		}).Error
	})
	return result, err
}

// RebuildUserStats 从事实表重建单个用户的汇总，供修复任务和运维接口调用。
func (s *CheckInService) RebuildUserStats(userID uint) (models.UserCheckInStat, error) {
	return models.RebuildUserCheckInStats(s.db, userID)
}

// CheckInExpReward 根据连续签到天数计算经验奖励。
func CheckInExpReward(streak int) int {
	if streak >= 50 {
		return 30
	}
	if streak <= 1 {
		return 1
	}
	if streak <= 15 {
		return streak
	}
	// 第 16 天到第 50 天从 15 平缓增长到 30，每次最多增加 1 点。
	return 15 + (streak-15)*15/35
}

func upsertCheckInStat(tx *gorm.DB, userID uint, date time.Time, currentStreak int) (models.UserCheckInStat, error) {
	var stat models.UserCheckInStat
	err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("user_id = ?", userID).First(&stat).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		stat = models.UserCheckInStat{
			UserID: userID, LastCheckInDate: &date, CurrentStreak: currentStreak, LongestStreak: currentStreak,
		}
		return stat, tx.Create(&stat).Error
	}
	if err != nil {
		return stat, err
	}
	longest := stat.LongestStreak
	if currentStreak > longest {
		longest = currentStreak
	}
	err = tx.Model(&models.UserCheckInStat{}).Where("user_id = ?", userID).Updates(map[string]interface{}{
		"last_check_in_date": date,
		"current_streak":     currentStreak,
		"longest_streak":     longest,
	}).Error
	stat.LastCheckInDate = &date
	stat.CurrentStreak = currentStreak
	stat.LongestStreak = longest
	return stat, err
}

func availableMakeupCards(stat models.UserCheckInStat) int {
	available := stat.MakeupCardsEarned + stat.MakeupCardsGranted - stat.MakeupCardsUsed
	if available < 0 {
		return 0
	}
	return available
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
