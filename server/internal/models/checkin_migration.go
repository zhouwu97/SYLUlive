package models

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"gorm.io/gorm"
)

const CheckInSchemaMigrationVersion = "20260716_01_checkin_facts_and_stats"
const CheckInMakeupCardMigrationVersion = "20260717_02_checkin_makeup_cards"
const CheckInMakeupCardScheduleMigrationVersion = "20261025_04_checkin_makeup_card_schedule"
const CheckInStreakReconciliationMigrationVersion = "20261109_05_checkin_streak_reconciliation"

// EnsureCheckInSchema 将旧的字符串日期迁移为 DATE，并在建立唯一约束前显式校验历史数据。
func EnsureCheckInSchema(db *gorm.DB) error {
	if db.Dialector.Name() == "postgres" && db.Migrator().HasTable(&CheckIn{}) {
		if err := migratePostgresCheckInDate(db); err != nil {
			return err
		}
	}
	if err := db.AutoMigrate(
		&AppSchemaMigration{},
		&CheckIn{},
		&UserCheckInStat{},
		&CheckInRepairLog{},
		&CheckInCompensationCampaign{},
		&CheckInCompensationEligibility{},
		&CheckInCompensationClaim{},
		&UserExperienceLedger{},
	); err != nil {
		return err
	}
	var appliedCount int64
	if err := db.Model(&AppSchemaMigration{}).Where("version = ?", CheckInSchemaMigrationVersion).Count(&appliedCount).Error; err != nil {
		return err
	}
	if appliedCount == 0 {
		if err := validateCheckInFacts(db); err != nil {
			return err
		}
		if err := backfillLastCheckInFacts(db); err != nil {
			return err
		}
	}
	var makeupCardAppliedCount int64
	if err := db.Model(&AppSchemaMigration{}).Where("version = ?", CheckInMakeupCardMigrationVersion).Count(&makeupCardAppliedCount).Error; err != nil {
		return err
	}
	if err := db.Exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_check_ins_user_date ON check_ins (user_id, check_in_date)").Error; err != nil {
		return fmt.Errorf("创建签到唯一约束: %w", err)
	}
	for _, statement := range []string{
		"CREATE UNIQUE INDEX IF NOT EXISTS idx_checkin_comp_eligibility ON check_in_compensation_eligibilities (campaign_id, user_id, check_in_date)",
		"CREATE UNIQUE INDEX IF NOT EXISTS idx_checkin_comp_claim ON check_in_compensation_claims (campaign_id, user_id, check_in_date)",
		"CREATE UNIQUE INDEX IF NOT EXISTS idx_exp_ledger_source ON user_experience_ledgers (user_id, source_type, source_id)",
	} {
		if err := db.Exec(statement).Error; err != nil {
			return fmt.Errorf("创建签到关联唯一约束: %w", err)
		}
	}
	if appliedCount == 0 {
		if err := RebuildAllUserCheckInStats(db); err != nil {
			return err
		}
		if err := db.Create(&AppSchemaMigration{Version: CheckInSchemaMigrationVersion, AppliedAt: time.Now()}).Error; err != nil {
			return err
		}
	}
	if makeupCardAppliedCount == 0 {
		if appliedCount != 0 {
			if err := RebuildAllUserCheckInStats(db); err != nil {
				return err
			}
		}
		if err := db.Create(&AppSchemaMigration{Version: CheckInMakeupCardMigrationVersion, AppliedAt: time.Now()}).Error; err != nil {
			return err
		}
	}
	// 旧用户也按新周期重建卡数；事务确保失败重试时不会留下部分更新或重复奖励。
	if err := db.Transaction(func(tx *gorm.DB) error {
		var count int64
		if err := tx.Model(&AppSchemaMigration{}).Where("version = ?", CheckInMakeupCardScheduleMigrationVersion).Count(&count).Error; err != nil {
			return err
		}
		if count != 0 {
			return nil
		}
		if err := RebuildAllUserCheckInStats(tx); err != nil {
			return err
		}
		return tx.Create(&AppSchemaMigration{Version: CheckInMakeupCardScheduleMigrationVersion, AppliedAt: time.Now()}).Error
	}); err != nil {
		return err
	}

	// 检查并修复所有签到连续天数和汇总不一致的账号，保证历史事实、当前汇总与发放卡数一致。
	return db.Transaction(func(tx *gorm.DB) error {
		var count int64
		if err := tx.Model(&AppSchemaMigration{}).Where("version = ?", CheckInStreakReconciliationMigrationVersion).Count(&count).Error; err != nil {
			return err
		}
		if count != 0 {
			return nil
		}
		if _, err := ReconcileInconsistentCheckInStats(tx, 0); err != nil {
			return err
		}
		return tx.Create(&AppSchemaMigration{Version: CheckInStreakReconciliationMigrationVersion, AppliedAt: time.Now()}).Error
	})
}

func migratePostgresCheckInDate(db *gorm.DB) error {
	var columnType string
	if err := db.Raw(`
SELECT data_type
FROM information_schema.columns
WHERE table_schema = current_schema() AND table_name = 'check_ins' AND column_name = 'check_in_date'
`).Scan(&columnType).Error; err != nil {
		return err
	}
	if columnType == "" || columnType == "date" {
		return nil
	}
	if columnType != "character varying" && columnType != "text" {
		return fmt.Errorf("check_ins.check_in_date 类型不受支持: %s", columnType)
	}
	type legacyDate struct {
		ID          uint
		CheckInDate string
	}
	var legacyDates []legacyDate
	if err := db.Raw("SELECT id, check_in_date FROM check_ins").Scan(&legacyDates).Error; err != nil {
		return err
	}
	for _, record := range legacyDates {
		if _, err := parseCheckInDate(record.CheckInDate); err != nil {
			return fmt.Errorf("check_ins.id=%d 的 check_in_date 非法: %w", record.ID, err)
		}
	}
	if err := db.Exec(`
ALTER TABLE check_ins
ALTER COLUMN check_in_date TYPE DATE
USING check_in_date::date
`).Error; err != nil {
		return fmt.Errorf("转换 check_ins.check_in_date 为 DATE: %w", err)
	}
	return nil
}

func validateCheckInFacts(db *gorm.DB) error {
	if !db.Migrator().HasTable(&CheckIn{}) {
		return nil
	}
	type duplicate struct {
		UserID uint
		Date   time.Time
		Count  int
	}
	var duplicates []duplicate
	if err := db.Model(&CheckIn{}).
		Select("user_id, check_in_date AS date, COUNT(*) AS count").
		Group("user_id, check_in_date").
		Having("COUNT(*) > 1").
		Limit(5).
		Find(&duplicates).Error; err != nil {
		return err
	}
	if len(duplicates) > 0 {
		first := duplicates[0]
		return fmt.Errorf("存在重复签到事实 user_id=%d date=%s，需先人工核对经验后再迁移", first.UserID, first.Date.Format("2006-01-02"))
	}
	return nil
}

// backfillLastCheckInFacts 只为旧汇总中缺失的最后签到日补一条零经验事实，避免迁移后当天状态倒退。
func backfillLastCheckInFacts(db *gorm.DB) error {
	if !db.Migrator().HasTable(&User{}) {
		return nil
	}
	var users []User
	if err := db.Select("id", "last_check_in_date").Where("last_check_in_date <> ''").Find(&users).Error; err != nil {
		return err
	}
	for _, user := range users {
		date, err := parseCheckInDate(user.LastCheckInDate)
		if err != nil {
			return fmt.Errorf("用户 %d 的 last_check_in_date 非法: %w", user.ID, err)
		}
		var count int64
		if err := db.Model(&CheckIn{}).Where("user_id = ? AND check_in_date = ?", user.ID, date).Count(&count).Error; err != nil {
			return err
		}
		if count == 0 {
			if err := db.Create(&CheckIn{UserID: user.ID, CheckInDate: date, StreakDays: 1, ExpEarned: 0}).Error; err != nil {
				return fmt.Errorf("补齐用户 %d 的最后签到事实: %w", user.ID, err)
			}
		}
	}
	return nil
}

// RebuildAllUserCheckInStats 根据事实表确定性重建所有用户的签到汇总，同时同步旧字段以兼容存量接口。
func RebuildAllUserCheckInStats(db *gorm.DB) error {
	if !db.Migrator().HasTable(&CheckIn{}) {
		return nil
	}
	var userIDs []uint
	if err := db.Model(&CheckIn{}).Distinct("user_id").Pluck("user_id", &userIDs).Error; err != nil {
		return err
	}
	for _, userID := range userIDs {
		if _, err := RebuildUserCheckInStats(db, userID); err != nil {
			return err
		}
	}
	return nil
}

// RebuildUserCheckInStats 按日期重算连续天数和汇总。它不修改已有经验，避免对历史资产做猜测性修正。
func RebuildUserCheckInStats(db *gorm.DB, userID uint) (UserCheckInStat, error) {
	var rebuilt UserCheckInStat
	err := db.Transaction(func(tx *gorm.DB) error {
		var existing UserCheckInStat
		existingErr := tx.Select("user_id", "makeup_cards_earned", "makeup_cards_granted").Where("user_id = ?", userID).First(&existing).Error
		if existingErr != nil && !errors.Is(existingErr, gorm.ErrRecordNotFound) {
			return existingErr
		}

		var records []CheckIn
		if err := tx.Where("user_id = ?", userID).Order("check_in_date ASC, id ASC").Find(&records).Error; err != nil {
			return err
		}
		if len(records) == 0 {
			if existing.MakeupCardsGranted == 0 {
				return tx.Where("user_id = ?", userID).Delete(&UserCheckInStat{}).Error
			}
			rebuilt = UserCheckInStat{UserID: userID, MakeupCardsGranted: existing.MakeupCardsGranted}
			return tx.Save(&rebuilt).Error
		}
		sort.SliceStable(records, func(i, j int) bool { return records[i].CheckInDate.Before(records[j].CheckInDate) })
		current, longest := 0, 0
		makeupCardsEarned, makeupCardsUsed := 0, 0
		var previous time.Time
		for index := range records {
			if index == 0 {
				current = 1
			} else if sameCheckInDate(records[index].CheckInDate, previous) {
				// 同一天重复记录，保留已计算的连续天数
			} else if sameCheckInDate(records[index].CheckInDate, previous.AddDate(0, 0, 1)) {
				current++
			} else {
				current = 1
			}
			if current > longest {
				longest = current
			}
			if (index == 0 || !sameCheckInDate(records[index].CheckInDate, previous)) && IsCheckInMakeupCardRewardDay(current) {
				makeupCardsEarned++
			}
			if records[index].IsMakeup {
				makeupCardsUsed++
			}
			if records[index].StreakDays != current {
				if err := tx.Model(&CheckIn{}).Where("id = ?", records[index].ID).Update("streak_days", current).Error; err != nil {
					return err
				}
			}
			previous = records[index].CheckInDate
		}
		last := dateOnly(previous)
		rebuilt = UserCheckInStat{
			UserID: userID, LastCheckInDate: &last, CurrentStreak: current, LongestStreak: longest,
			MakeupCardsEarned:  makeupCardsEarned,
			MakeupCardsGranted: existing.MakeupCardsGranted + max(0, existing.MakeupCardsEarned-makeupCardsEarned),
			MakeupCardsUsed:    makeupCardsUsed,
		}
		if err := tx.Save(&rebuilt).Error; err != nil {
			return err
		}
		return tx.Model(&User{}).Where("id = ?", userID).Update("last_check_in_date", last.Format("2006-01-02")).Error
	})
	return rebuilt, err
}

func parseCheckInDate(raw string) (time.Time, error) {
	parsed, err := time.Parse("2006-01-02", strings.TrimSpace(raw))
	if err != nil {
		return time.Time{}, err
	}
	return dateOnly(parsed), nil
}

func dateOnly(value time.Time) time.Time {
	return time.Date(value.Year(), value.Month(), value.Day(), 0, 0, 0, 0, time.UTC)
}

func sameCheckInDate(left, right time.Time) bool {
	return left.Format("2006-01-02") == right.Format("2006-01-02")
}

// CheckInInconsistency 记录单个用户签到事实、汇总或旧字段的不一致详情。
type CheckInInconsistency struct {
	UserID          uint       `json:"user_id"`
	LastCheckInDate *time.Time `json:"last_check_in_date,omitempty"`
	FactCount       int        `json:"fact_count"`
	CurrentStreak   int        `json:"current_streak"`
	ExpectedStreak  int        `json:"expected_streak"`
	LongestStreak   int        `json:"longest_streak"`
	ExpectedLongest int        `json:"expected_longest"`
	CardsEarned     int        `json:"cards_earned"`
	ExpectedCards   int        `json:"expected_cards"`
	Reason          string     `json:"reason"`
}

// ReconcileReport 记录全局签到对账与修复结果。
type ReconcileReport struct {
	TotalUsersScanned int                    `json:"total_users_scanned"`
	InconsistentCount int                    `json:"inconsistent_count"`
	RepairedCount     int                    `json:"repaired_count"`
	Details           []CheckInInconsistency `json:"details"`
}

// InspectUserCheckInStats 校验指定用户的签到事实与汇总一致性。一致时返回 nil。
func InspectUserCheckInStats(db *gorm.DB, userID uint) (*CheckInInconsistency, error) {
	var records []CheckIn
	if err := db.Where("user_id = ?", userID).Order("check_in_date ASC, id ASC").Find(&records).Error; err != nil {
		return nil, err
	}
	var stat UserCheckInStat
	statErr := db.Where("user_id = ?", userID).First(&stat).Error
	if statErr != nil && !errors.Is(statErr, gorm.ErrRecordNotFound) {
		return nil, statErr
	}
	var user User
	userErr := db.Select("id", "last_check_in_date").Where("id = ?", userID).First(&user).Error
	if userErr != nil && !errors.Is(userErr, gorm.ErrRecordNotFound) {
		return nil, userErr
	}

	if len(records) == 0 {
		if errors.Is(statErr, gorm.ErrRecordNotFound) {
			if userErr == nil && user.LastCheckInDate != "" {
				return &CheckInInconsistency{
					UserID: userID, FactCount: 0,
					Reason: "无签到事实但用户表包含最后签到日",
				}, nil
			}
			return nil, nil
		}
		if stat.CurrentStreak != 0 || stat.LongestStreak != 0 || stat.LastCheckInDate != nil {
			return &CheckInInconsistency{
				UserID: userID, FactCount: 0,
				CurrentStreak: stat.CurrentStreak, LongestStreak: stat.LongestStreak,
				Reason: "无签到事实但汇总包含非零连续天数或日期",
			}, nil
		}
		if userErr == nil && user.LastCheckInDate != "" {
			return &CheckInInconsistency{
				UserID: userID, FactCount: 0,
				Reason: "无签到事实但用户表包含最后签到日",
			}, nil
		}
		return nil, nil
	}

	sort.SliceStable(records, func(i, j int) bool { return records[i].CheckInDate.Before(records[j].CheckInDate) })
	current, longest := 0, 0
	cardsEarned := 0
	var previous time.Time
	var reasons []string

	for index := range records {
		expected := 1
		if index == 0 {
			expected = 1
		} else if sameCheckInDate(records[index].CheckInDate, previous) {
			expected = current
		} else if sameCheckInDate(records[index].CheckInDate, previous.AddDate(0, 0, 1)) {
			expected = current + 1
		} else {
			expected = 1
		}
		current = expected
		if current > longest {
			longest = current
		}
		if (index == 0 || !sameCheckInDate(records[index].CheckInDate, previous)) && IsCheckInMakeupCardRewardDay(current) {
			cardsEarned++
		}
		if records[index].StreakDays != current {
			reasons = append(reasons, fmt.Sprintf("签到事实 %s 连续天数不一致（记录:%d 期望:%d）",
				records[index].CheckInDate.Format("2006-01-02"), records[index].StreakDays, current))
		}
		previous = records[index].CheckInDate
	}

	last := dateOnly(previous)
	recordedCurrent := 0
	recordedLongest := 0
	recordedCards := 0
	var recordedLastDate *time.Time
	if errors.Is(statErr, gorm.ErrRecordNotFound) {
		reasons = append(reasons, "签到汇总记录缺失")
	} else {
		recordedCurrent = stat.CurrentStreak
		recordedLongest = stat.LongestStreak
		recordedCards = stat.MakeupCardsEarned
		recordedLastDate = stat.LastCheckInDate
		if stat.LastCheckInDate == nil || !sameCheckInDate(*stat.LastCheckInDate, last) {
			reasons = append(reasons, "汇总最后签到日期与事实不一致")
		}
		if stat.CurrentStreak != current {
			reasons = append(reasons, fmt.Sprintf("汇总连续天数与事实不一致（记录:%d 期望:%d）", stat.CurrentStreak, current))
		}
		if stat.LongestStreak != longest {
			reasons = append(reasons, fmt.Sprintf("汇总最长连续天数与事实不一致（记录:%d 期望:%d）", stat.LongestStreak, longest))
		}
		if stat.MakeupCardsEarned != cardsEarned {
			reasons = append(reasons, fmt.Sprintf("汇总补签卡发放数与事实不一致（记录:%d 期望:%d）", stat.MakeupCardsEarned, cardsEarned))
		}
	}

	if userErr == nil && user.LastCheckInDate != last.Format("2006-01-02") {
		reasons = append(reasons, fmt.Sprintf("用户表最后签到日与事实不一致（记录:%s 期望:%s）", user.LastCheckInDate, last.Format("2006-01-02")))
	}

	if len(reasons) == 0 {
		return nil, nil
	}

	return &CheckInInconsistency{
		UserID:          userID,
		LastCheckInDate: recordedLastDate,
		FactCount:       len(records),
		CurrentStreak:   recordedCurrent,
		ExpectedStreak:  current,
		LongestStreak:   recordedLongest,
		ExpectedLongest: longest,
		CardsEarned:     recordedCards,
		ExpectedCards:   cardsEarned,
		Reason:          strings.Join(reasons, "; "),
	}, nil
}

// InspectAllUserCheckInStats 扫描全量用户并报告所有存在签到天数或汇总不一致的账号。
func InspectAllUserCheckInStats(db *gorm.DB) ([]CheckInInconsistency, error) {
	var userIDs []uint
	if db.Migrator().HasTable(&CheckIn{}) {
		var checkInUserIDs []uint
		if err := db.Model(&CheckIn{}).Distinct("user_id").Pluck("user_id", &checkInUserIDs).Error; err != nil {
			return nil, err
		}
		userIDs = append(userIDs, checkInUserIDs...)
	}
	if db.Migrator().HasTable(&UserCheckInStat{}) {
		var statUserIDs []uint
		if err := db.Model(&UserCheckInStat{}).Distinct("user_id").Pluck("user_id", &statUserIDs).Error; err != nil {
			return nil, err
		}
		userIDs = append(userIDs, statUserIDs...)
	}
	seen := make(map[uint]bool, len(userIDs))
	uniqueIDs := make([]uint, 0, len(userIDs))
	for _, id := range userIDs {
		if !seen[id] && id > 0 {
			seen[id] = true
			uniqueIDs = append(uniqueIDs, id)
		}
	}
	sort.Slice(uniqueIDs, func(i, j int) bool { return uniqueIDs[i] < uniqueIDs[j] })

	inconsistencies := make([]CheckInInconsistency, 0)
	for _, uid := range uniqueIDs {
		item, err := InspectUserCheckInStats(db, uid)
		if err != nil {
			return nil, fmt.Errorf("检查用户 %d 签到状态失败: %w", uid, err)
		}
		if item != nil {
			inconsistencies = append(inconsistencies, *item)
		}
	}
	return inconsistencies, nil
}

// ReconcileInconsistentCheckInStats 检查并修复所有签到天数不一致的账号，并记录审计日志。
func ReconcileInconsistentCheckInStats(db *gorm.DB, operatorID uint) (ReconcileReport, error) {
	report := ReconcileReport{Details: make([]CheckInInconsistency, 0)}
	inconsistencies, err := InspectAllUserCheckInStats(db)
	if err != nil {
		return report, err
	}
	report.InconsistentCount = len(inconsistencies)

	var allUsersCount int64
	if db.Migrator().HasTable(&CheckIn{}) {
		db.Model(&CheckIn{}).Distinct("user_id").Count(&allUsersCount)
	}
	report.TotalUsersScanned = int(allUsersCount)

	for _, item := range inconsistencies {
		rebuilt, rebuildErr := RebuildUserCheckInStats(db, item.UserID)
		if rebuildErr != nil {
			return report, fmt.Errorf("修复用户 %d 连续签到天数失败: %w", item.UserID, rebuildErr)
		}
		repairLog := CheckInRepairLog{
			UserID:         item.UserID,
			OperatorID:     operatorID,
			Action:         "reconcile_streak",
			Reason:         fmt.Sprintf("签到天数对账修复：%s", item.Reason),
			PreviousStreak: item.CurrentStreak,
			NewStreak:      rebuilt.CurrentStreak,
		}
		if logErr := db.Create(&repairLog).Error; logErr != nil {
			return report, fmt.Errorf("写入用户 %d 签到修复审计日志失败: %w", item.UserID, logErr)
		}
		report.RepairedCount++
		report.Details = append(report.Details, item)
	}
	return report, nil
}
