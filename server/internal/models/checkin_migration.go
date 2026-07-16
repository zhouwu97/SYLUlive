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
	return nil
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
		existingErr := tx.Select("user_id", "makeup_cards_granted").Where("user_id = ?", userID).First(&existing).Error
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
			if index == 0 || !sameCheckInDate(records[index].CheckInDate, previous.AddDate(0, 0, 1)) {
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
			MakeupCardsEarned: makeupCardsEarned, MakeupCardsGranted: existing.MakeupCardsGranted,
			MakeupCardsUsed: makeupCardsUsed,
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
