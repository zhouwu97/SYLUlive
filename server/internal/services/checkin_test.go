package services

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestCheckInIsIdempotentAndBuildsStreak(t *testing.T) {
	db := newCheckInTestDB(t)
	user := createCheckInTestUser(t, db, "checkin-idempotent")
	service := NewCheckInService(db)
	loc := time.FixedZone("CST", 8*3600)

	first, err := service.CheckIn(user.ID, time.Date(2026, 7, 16, 10, 0, 0, 0, loc))
	require.NoError(t, err)
	require.False(t, first.Already)
	require.Equal(t, 1, first.StreakDays)
	require.Equal(t, 1, first.ExpEarned)
	require.Equal(t, 11, first.TotalExp)

	retry, err := service.CheckIn(user.ID, time.Date(2026, 7, 16, 10, 1, 0, 0, loc))
	require.NoError(t, err)
	require.True(t, retry.Already)
	require.Equal(t, 1, retry.StreakDays)
	require.Zero(t, retry.ExpEarned)
	require.Equal(t, 11, retry.TotalExp)

	secondDay, err := service.CheckIn(user.ID, time.Date(2026, 7, 17, 10, 0, 0, 0, loc))
	require.NoError(t, err)
	require.Equal(t, 2, secondDay.StreakDays)
	require.Equal(t, 2, secondDay.ExpEarned)

	thirdDay, err := service.CheckIn(user.ID, time.Date(2026, 7, 18, 10, 0, 0, 0, loc))
	require.NoError(t, err)
	require.Equal(t, 3, thirdDay.StreakDays)
	require.Equal(t, 3, thirdDay.ExpEarned)

	var checkInCount, ledgerCount int64
	require.NoError(t, db.Model(&models.CheckIn{}).Where("user_id = ?", user.ID).Count(&checkInCount).Error)
	require.NoError(t, db.Model(&models.UserExperienceLedger{}).Where("user_id = ? AND source_type = ?", user.ID, "checkin").Count(&ledgerCount).Error)
	require.Equal(t, int64(3), checkInCount)
	require.Equal(t, int64(3), ledgerCount)

	var stat models.UserCheckInStat
	require.NoError(t, db.First(&stat, "user_id = ?", user.ID).Error)
	require.Equal(t, 3, stat.CurrentStreak)
	require.Equal(t, 3, stat.LongestStreak)
}

func TestCheckInStatusUsesFactsAndResetsAfterGap(t *testing.T) {
	db := newCheckInTestDB(t)
	user := createCheckInTestUser(t, db, "checkin-status")
	service := NewCheckInService(db)
	loc := time.FixedZone("CST", 8*3600)

	_, err := service.CheckIn(user.ID, time.Date(2026, 7, 16, 9, 0, 0, 0, loc))
	require.NoError(t, err)
	status, err := service.Status(user.ID, time.Date(2026, 7, 17, 9, 0, 0, 0, loc))
	require.NoError(t, err)
	require.False(t, status.CheckedIn)
	require.Equal(t, 1, status.StreakDays)

	status, err = service.Status(user.ID, time.Date(2026, 7, 18, 9, 0, 0, 0, loc))
	require.NoError(t, err)
	require.False(t, status.CheckedIn)
	require.Zero(t, status.StreakDays)
	require.Equal(t, 1, status.NextExp)
}

func TestCheckInAwardsFirstMakeupCardAfterSevenDaysThenEveryFourteen(t *testing.T) {
	db := newCheckInTestDB(t)
	user := createCheckInTestUser(t, db, "checkin-makeup-card-award")
	service := NewCheckInService(db)
	loc := time.FixedZone("CST", 8*3600)
	start := time.Date(2026, 5, 26, 9, 0, 0, 0, loc)

	awardDays := map[int]int{7: 1, 21: 2, 35: 3, 49: 4}
	expectedCards := 0
	for day := 0; day < 49; day++ {
		result, err := service.CheckIn(user.ID, start.AddDate(0, 0, day))
		require.NoError(t, err)
		if total, awarded := awardDays[day+1]; awarded {
			expectedCards = total
			require.Equal(t, 1, result.MakeupCardsAwarded)
			retry, err := service.CheckIn(user.ID, start.AddDate(0, 0, day))
			require.NoError(t, err)
			require.True(t, retry.Already)
			require.Zero(t, retry.MakeupCardsAwarded)
			require.Equal(t, result.MakeupCards, retry.MakeupCards)
		} else {
			require.Zero(t, result.MakeupCardsAwarded)
		}
		require.Equal(t, expectedCards, result.MakeupCards, "day %d", day+1)
	}

	status, err := service.Status(user.ID, start.AddDate(0, 0, 48))
	require.NoError(t, err)
	require.Equal(t, 4, status.MakeupCards)
}

func TestCheckInRestartsMakeupCardScheduleAfterEveryGap(t *testing.T) {
	db := newCheckInTestDB(t)
	user := createCheckInTestUser(t, db, "checkin-makeup-card-reset")
	service := NewCheckInService(db)
	start := time.Date(2026, 5, 1, 9, 0, 0, 0, time.FixedZone("CST", 8*3600))
	for segment := 0; segment < 3; segment++ {
		for day := 1; day <= 21; day++ {
			result, err := service.CheckIn(user.ID, start.AddDate(0, 0, segment*22+day-1))
			require.NoError(t, err)
			require.Equal(t, day, result.StreakDays)
			expected := segment * 2
			if day >= 7 {
				expected++
			}
			if day == 21 {
				expected++
			}
			require.Equal(t, expected, result.MakeupCards, "segment %d day %d", segment+1, day)
			if day == 7 || day == 21 {
				require.Equal(t, 1, result.MakeupCardsAwarded)
			} else {
				require.Zero(t, result.MakeupCardsAwarded)
			}
		}
	}
}

func TestMakeupCheckInConsumesCardAndRecalculatesLaterExperience(t *testing.T) {
	db := newCheckInTestDB(t)
	user := createCheckInTestUser(t, db, "checkin-makeup-recalculate")
	service := NewCheckInService(db)
	loc := time.FixedZone("CST", 8*3600)
	mayStart := time.Date(2026, 5, 1, 9, 0, 0, 0, loc)
	for day := 0; day < 7; day++ {
		_, err := service.CheckIn(user.ID, mayStart.AddDate(0, 0, day))
		require.NoError(t, err)
	}
	_, err := service.CheckIn(user.ID, time.Date(2026, 7, 1, 9, 0, 0, 0, loc))
	require.NoError(t, err)
	_, err = service.CheckIn(user.ID, time.Date(2026, 7, 3, 9, 0, 0, 0, loc))
	require.NoError(t, err)

	result, err := service.Makeup(
		user.ID,
		time.Date(2026, 7, 2, 0, 0, 0, 0, loc),
		time.Date(2026, 7, 4, 9, 0, 0, 0, loc),
	)
	require.NoError(t, err)
	require.False(t, result.Already)
	require.Equal(t, 2, result.StreakDays)
	require.Equal(t, 2, result.CheckInExp)
	require.Equal(t, 4, result.ExpEarned)
	require.Zero(t, result.MakeupCards)

	var julyThird models.CheckIn
	require.NoError(t, db.Where("user_id = ? AND check_in_date = ?", user.ID, time.Date(2026, 7, 3, 0, 0, 0, 0, time.UTC)).First(&julyThird).Error)
	require.Equal(t, 3, julyThird.StreakDays)
	require.Equal(t, 3, julyThird.ExpEarned)
	require.False(t, julyThird.IsMakeup)

	var makeupRecord models.CheckIn
	require.NoError(t, db.Where("user_id = ? AND check_in_date = ?", user.ID, time.Date(2026, 7, 2, 0, 0, 0, 0, time.UTC)).First(&makeupRecord).Error)
	require.True(t, makeupRecord.IsMakeup)

	retry, err := service.Makeup(
		user.ID,
		time.Date(2026, 7, 2, 0, 0, 0, 0, loc),
		time.Date(2026, 7, 4, 9, 0, 0, 0, loc),
	)
	require.NoError(t, err)
	require.True(t, retry.Already)
	require.Zero(t, retry.ExpEarned)
	require.Zero(t, retry.MakeupCards)

	var stat models.UserCheckInStat
	require.NoError(t, db.First(&stat, "user_id = ?", user.ID).Error)
	require.Equal(t, 1, stat.MakeupCardsEarned)
	require.Equal(t, 1, stat.MakeupCardsUsed)
	require.Equal(t, 3, stat.CurrentStreak)
}

func TestMakeupCheckInRequiresCardAndCurrentMonthPastDate(t *testing.T) {
	db := newCheckInTestDB(t)
	user := createCheckInTestUser(t, db, "checkin-makeup-validation")
	service := NewCheckInService(db)
	loc := time.FixedZone("CST", 8*3600)
	now := time.Date(2026, 7, 17, 9, 0, 0, 0, loc)

	_, err := service.Makeup(user.ID, time.Date(2026, 7, 16, 0, 0, 0, 0, loc), now)
	require.ErrorIs(t, err, ErrNoMakeupCards)
	_, err = service.Makeup(user.ID, time.Date(2026, 6, 30, 0, 0, 0, 0, loc), now)
	require.ErrorIs(t, err, ErrMakeupDateNotAllowed)
	_, err = service.Makeup(user.ID, now, now)
	require.ErrorIs(t, err, ErrMakeupDateNotAllowed)
}

func TestMakeupCheckInConsumesGrantedCard(t *testing.T) {
	db := newCheckInTestDB(t)
	user := createCheckInTestUser(t, db, "checkin-granted-makeup-card")
	require.NoError(t, db.Create(&models.UserCheckInStat{
		UserID: user.ID, MakeupCardsGranted: 2,
	}).Error)
	service := NewCheckInService(db)
	loc := time.FixedZone("CST", 8*3600)

	result, err := service.Makeup(
		user.ID,
		time.Date(2026, 7, 16, 0, 0, 0, 0, loc),
		time.Date(2026, 7, 17, 9, 0, 0, 0, loc),
	)
	require.NoError(t, err)
	require.Equal(t, 1, result.MakeupCards)

	var stat models.UserCheckInStat
	require.NoError(t, db.First(&stat, "user_id = ?", user.ID).Error)
	require.Zero(t, stat.MakeupCardsEarned)
	require.Equal(t, 2, stat.MakeupCardsGranted)
	require.Equal(t, 1, stat.MakeupCardsUsed)
}

func TestMakeupRecalculatesFirstSevenThenFourteenDayMilestones(t *testing.T) {
	for _, tc := range []struct {
		days, missingDay, totalCards, awarded int
	}{
		{7, 4, 1, 1},
		{14, 7, 1, 0},
		{21, 7, 2, 1},
	} {
		t.Run(fmt.Sprint(tc.days), func(t *testing.T) {
			db := newCheckInTestDB(t)
			user := createCheckInTestUser(t, db, "checkin-makeup-replacement-card")
			require.NoError(t, db.Create(&models.UserCheckInStat{UserID: user.ID, MakeupCardsGranted: 1}).Error)
			service := NewCheckInService(db)
			loc := time.FixedZone("CST", 8*3600)
			start := time.Date(2026, 8, 1, 9, 0, 0, 0, loc)
			for day := 1; day <= tc.days; day++ {
				if day == tc.missingDay {
					continue
				}
				_, err := service.CheckIn(user.ID, start.AddDate(0, 0, day-1))
				require.NoError(t, err)
			}

			target, now := start.AddDate(0, 0, tc.missingDay-1), start.AddDate(0, 0, tc.days)
			result, err := service.Makeup(user.ID, target, now)
			require.NoError(t, err)
			require.Equal(t, tc.awarded, result.MakeupCardsAwarded)
			require.Equal(t, tc.totalCards, result.MakeupCards)

			retry, err := service.Makeup(user.ID, target, now)
			require.NoError(t, err)
			require.True(t, retry.Already)
			require.Zero(t, retry.MakeupCardsAwarded)
			require.Equal(t, result.MakeupCards, retry.MakeupCards)

			var stat models.UserCheckInStat
			require.NoError(t, db.First(&stat, "user_id = ?", user.ID).Error)
			require.Equal(t, tc.totalCards, stat.MakeupCardsEarned)
			require.Equal(t, 1, stat.MakeupCardsGranted)
			require.Equal(t, 1, stat.MakeupCardsUsed)
			require.Equal(t, tc.days, stat.CurrentStreak)
		})
	}
}

func TestMakeupJoiningRewardedStreaksPreservesIssuedCards(t *testing.T) {
	db := newCheckInTestDB(t)
	user := createCheckInTestUser(t, db, "checkin-makeup-merge-rewards")
	service := NewCheckInService(db)
	start := time.Date(2026, 7, 1, 9, 0, 0, 0, time.FixedZone("CST", 8*3600))
	for day := 1; day <= 15; day++ {
		if day == 8 {
			continue
		}
		_, err := service.CheckIn(user.ID, start.AddDate(0, 0, day-1))
		require.NoError(t, err)
	}
	target, now := start.AddDate(0, 0, 7), start.AddDate(0, 0, 15)
	status, err := service.Status(user.ID, now)
	require.NoError(t, err)
	require.Equal(t, 2, status.MakeupCards)
	result, err := service.Makeup(user.ID, target, now)
	require.NoError(t, err)
	require.Equal(t, 1, result.MakeupCards)
	require.Zero(t, result.MakeupCardsAwarded)
	retry, err := service.Makeup(user.ID, target, now)
	require.NoError(t, err)
	require.True(t, retry.Already)
	require.Equal(t, 1, retry.MakeupCards)

	for range 2 {
		rebuilt, err := service.RebuildUserStats(user.ID)
		require.NoError(t, err)
		require.Equal(t, 1, rebuilt.MakeupCardsEarned)
		require.Equal(t, 1, rebuilt.MakeupCardsGranted)
		require.Equal(t, 1, rebuilt.MakeupCardsUsed)
	}
	var log models.CheckInRepairLog
	require.NoError(t, db.Where("user_id = ? AND action = ?", user.ID, "user_makeup").First(&log).Error)
	require.Contains(t, log.Reason, "保留历史奖励补签卡 1 张")
	for day := 16; day <= 21; day++ {
		result, err := service.CheckIn(user.ID, start.AddDate(0, 0, day-1))
		require.NoError(t, err)
		if day < 21 {
			require.Zero(t, result.MakeupCardsAwarded)
			require.Equal(t, 1, result.MakeupCards)
		} else {
			require.Equal(t, 1, result.MakeupCardsAwarded)
			require.Equal(t, 2, result.MakeupCards)
		}
	}
	makeup, err := service.Makeup(user.ID, start.AddDate(0, 0, 21), start.AddDate(0, 0, 22))
	require.NoError(t, err)
	require.Zero(t, makeup.MakeupCardsAwarded)
	require.Equal(t, 1, makeup.MakeupCards)
}

func TestCheckInExpRewardThresholds(t *testing.T) {
	tests := []struct {
		streak int
		reward int
	}{
		{streak: 1, reward: 1},
		{streak: 2, reward: 2},
		{streak: 3, reward: 3},
		{streak: 10, reward: 10},
		{streak: 15, reward: 15},
		{streak: 16, reward: 15},
		{streak: 18, reward: 16},
		{streak: 30, reward: 21},
		{streak: 49, reward: 29},
		{streak: 50, reward: 30},
		{streak: 365, reward: 30},
	}
	for _, tt := range tests {
		require.Equal(t, tt.reward, CheckInExpReward(tt.streak))
	}
	for day := 2; day <= 50; day++ {
		previous := CheckInExpReward(day - 1)
		current := CheckInExpReward(day)
		require.GreaterOrEqual(t, current, previous)
		require.LessOrEqual(t, current-previous, 1)
	}
	for day := 2; day <= 15; day++ {
		require.Equal(t, 1, CheckInExpReward(day)-CheckInExpReward(day-1))
	}
}

func TestCheckInCalendarReturnsOnlyRequestedMonth(t *testing.T) {
	db := newCheckInTestDB(t)
	user := createCheckInTestUser(t, db, "checkin-calendar")
	records := []models.CheckIn{
		{UserID: user.ID, CheckInDate: time.Date(2026, 6, 30, 0, 0, 0, 0, time.UTC), StreakDays: 1, ExpEarned: 1},
		{UserID: user.ID, CheckInDate: time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC), StreakDays: 2, ExpEarned: 1},
		{UserID: user.ID, CheckInDate: time.Date(2026, 7, 16, 0, 0, 0, 0, time.UTC), StreakDays: 1, ExpEarned: 1},
		{UserID: user.ID, CheckInDate: time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC), StreakDays: 2, ExpEarned: 1},
	}
	require.NoError(t, db.Create(&records).Error)
	require.NoError(t, db.Create(&models.UserCheckInStat{UserID: user.ID, LongestStreak: 12}).Error)

	calendar, err := NewCheckInService(db).Calendar(user.ID, time.Date(2026, 7, 18, 10, 0, 0, 0, time.UTC))
	require.NoError(t, err)
	require.Equal(t, "2026-07", calendar.Month.Format("2006-01"))
	require.Equal(t, 12, calendar.LongestStreak)
	require.Len(t, calendar.Records, 2)
	require.Equal(t, "2026-07-01", FormatCheckInDate(calendar.Records[0].CheckInDate))
	require.Equal(t, "2026-07-16", FormatCheckInDate(calendar.Records[1].CheckInDate))
}

func TestRebuildUserCheckInStatsDoesNotChangeExperience(t *testing.T) {
	db := newCheckInTestDB(t)
	user := createCheckInTestUser(t, db, "checkin-rebuild")
	dates := []time.Time{
		time.Date(2026, 7, 10, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 7, 11, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 7, 13, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 7, 14, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 7, 15, 0, 0, 0, 0, time.UTC),
	}
	for _, date := range dates {
		require.NoError(t, db.Create(&models.CheckIn{UserID: user.ID, CheckInDate: date, StreakDays: 99, ExpEarned: 7}).Error)
	}
	require.NoError(t, db.Create(&models.UserCheckInStat{
		UserID: user.ID, MakeupCardsGranted: 2,
	}).Error)

	rebuilt, err := models.RebuildUserCheckInStats(db, user.ID)
	require.NoError(t, err)
	require.Equal(t, 3, rebuilt.CurrentStreak)
	require.Equal(t, 3, rebuilt.LongestStreak)
	require.Equal(t, 2, rebuilt.MakeupCardsGranted)

	var refreshed models.User
	require.NoError(t, db.First(&refreshed, user.ID).Error)
	require.Equal(t, 10, refreshed.Exp)
	require.Equal(t, "2026-07-15", refreshed.LastCheckInDate)

	var records []models.CheckIn
	require.NoError(t, db.Where("user_id = ?", user.ID).Order("check_in_date ASC").Find(&records).Error)
	require.Equal(t, []int{1, 2, 1, 2, 3}, []int{records[0].StreakDays, records[1].StreakDays, records[2].StreakDays, records[3].StreakDays, records[4].StreakDays})
}

func TestRebuildUserCheckInStatsPreservesGrantedCardsWithoutRecords(t *testing.T) {
	db := newCheckInTestDB(t)
	user := createCheckInTestUser(t, db, "checkin-rebuild-granted-cards")
	require.NoError(t, db.Create(&models.UserCheckInStat{
		UserID: user.ID, MakeupCardsGranted: 2,
	}).Error)

	rebuilt, err := models.RebuildUserCheckInStats(db, user.ID)
	require.NoError(t, err)
	require.Equal(t, user.ID, rebuilt.UserID)
	require.Equal(t, 2, rebuilt.MakeupCardsGranted)

	var stat models.UserCheckInStat
	require.NoError(t, db.First(&stat, "user_id = ?", user.ID).Error)
	require.Equal(t, 2, stat.MakeupCardsGranted)
}

func TestMakeupCardScheduleMigrationRebuildsHistoryAndIsIdempotent(t *testing.T) {
	db := newCheckInTestDB(t)
	user := createCheckInTestUser(t, db, "checkin-weekly-migration")
	grantOnly := createCheckInTestUser(t, db, "checkin-weekly-grant-only")
	missingStat := createCheckInTestUser(t, db, "checkin-weekly-missing-stat")
	for _, segment := range []struct {
		start time.Time
		days  int
	}{
		{time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC), 30},
		{time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC), 14},
	} {
		for day := 0; day < segment.days; day++ {
			require.NoError(t, db.Create(&models.CheckIn{
				UserID: user.ID, CheckInDate: segment.start.AddDate(0, 0, day),
				StreakDays: day + 1, ExpEarned: 7, IsMakeup: segment.start.Month() == time.May && day == 2,
			}).Error)
		}
	}
	for day := 1; day <= 7; day++ {
		require.NoError(t, db.Create(&models.CheckIn{
			UserID: missingStat.ID, CheckInDate: time.Date(2026, 7, day, 0, 0, 0, 0, time.UTC),
			StreakDays: day, ExpEarned: 1,
		}).Error)
	}
	last := time.Date(2026, 7, 14, 0, 0, 0, 0, time.UTC)
	require.NoError(t, db.Create(&models.UserCheckInStat{
		UserID: user.ID, LastCheckInDate: &last, CurrentStreak: 14, LongestStreak: 30,
		MakeupCardsEarned: 1, MakeupCardsGranted: 2, MakeupCardsUsed: 1,
	}).Error)
	require.NoError(t, db.Create(&models.UserCheckInStat{UserID: grantOnly.ID, MakeupCardsGranted: 3}).Error)
	var ledgerFact models.CheckIn
	require.NoError(t, db.Where("user_id = ? AND check_in_date = ?", user.ID,
		time.Date(2026, 5, 13, 0, 0, 0, 0, time.UTC)).First(&ledgerFact).Error)
	require.NoError(t, db.Create(&models.UserExperienceLedger{
		UserID: user.ID, SourceType: "checkin", SourceID: ledgerFact.ID, Delta: 13, Reason: "历史经验",
	}).Error)
	require.NoError(t, db.Where("version = ?", models.CheckInMakeupCardScheduleMigrationVersion).Delete(&models.AppSchemaMigration{}).Error)

	for range 2 {
		require.NoError(t, models.EnsureCheckInSchema(db))
		var stat models.UserCheckInStat
		require.NoError(t, db.First(&stat, "user_id = ?", user.ID).Error)
		require.Equal(t, 3, stat.MakeupCardsEarned) // 30 天 2 张，另一个连续 14 天 1 张。
		require.Equal(t, 2, stat.MakeupCardsGranted)
		require.Equal(t, 1, stat.MakeupCardsUsed)
		require.Equal(t, 14, stat.CurrentStreak)
		require.Equal(t, 30, stat.LongestStreak)
		var missing models.UserCheckInStat
		require.NoError(t, db.First(&missing, "user_id = ?", missingStat.ID).Error)
		require.Equal(t, 1, missing.MakeupCardsEarned)
		var granted models.UserCheckInStat
		require.NoError(t, db.First(&granted, "user_id = ?", grantOnly.ID).Error)
		require.Equal(t, 3, granted.MakeupCardsGranted)
		var refreshed models.User
		require.NoError(t, db.First(&refreshed, user.ID).Error)
		require.Equal(t, 10, refreshed.Exp)
		var records []models.CheckIn
		require.NoError(t, db.Where("user_id = ?", user.ID).Find(&records).Error)
		require.Len(t, records, 44)
		for _, record := range records {
			require.Equal(t, 7, record.ExpEarned)
		}
		var ledger models.UserExperienceLedger
		require.NoError(t, db.Where("user_id = ?", user.ID).First(&ledger).Error)
		require.Equal(t, 13, ledger.Delta)
	}
	var count int64
	require.NoError(t, db.Model(&models.AppSchemaMigration{}).Where("version = ?", models.CheckInMakeupCardScheduleMigrationVersion).Count(&count).Error)
	require.Equal(t, int64(1), count)

	service := NewCheckInService(db)
	loc := time.FixedZone("CST", 8*3600)
	now := time.Date(2026, 7, 17, 9, 0, 0, 0, loc)
	status, err := service.Status(user.ID, now)
	require.NoError(t, err)
	require.Equal(t, 4, status.MakeupCards)
	target := now.AddDate(0, 0, -1)
	makeup, err := service.Makeup(user.ID, target, now)
	require.NoError(t, err)
	require.Equal(t, 3, makeup.MakeupCards)
	require.Zero(t, makeup.MakeupCardsAwarded)
	require.Equal(t, 11, makeup.TotalExp)
	retry, err := service.Makeup(user.ID, target, now)
	require.NoError(t, err)
	require.True(t, retry.Already)
	require.Equal(t, 3, retry.MakeupCards)
}

func TestMakeupCardScheduleMigrationRollsBackAndCanRetry(t *testing.T) {
	db := newCheckInTestDB(t)
	user := createCheckInTestUser(t, db, "checkin-weekly-migration-retry")
	for day := 1; day <= 14; day++ {
		require.NoError(t, db.Create(&models.CheckIn{
			UserID: user.ID, CheckInDate: time.Date(2026, 7, day, 0, 0, 0, 0, time.UTC),
			StreakDays: day, ExpEarned: 1,
		}).Error)
	}
	require.NoError(t, db.Create(&models.UserCheckInStat{UserID: user.ID, MakeupCardsGranted: 2}).Error)
	require.NoError(t, db.Where("version = ?", models.CheckInMakeupCardScheduleMigrationVersion).Delete(&models.AppSchemaMigration{}).Error)
	require.NoError(t, db.Callback().Create().Before("gorm:create").Register("test:reject_weekly_marker", func(tx *gorm.DB) {
		if marker, ok := tx.Statement.Dest.(*models.AppSchemaMigration); ok && marker.Version == models.CheckInMakeupCardScheduleMigrationVersion {
			tx.AddError(fmt.Errorf("test weekly migration marker failure"))
		}
	}))
	err := models.EnsureCheckInSchema(db)
	require.ErrorContains(t, err, "test weekly migration marker failure")
	var stat models.UserCheckInStat
	require.NoError(t, db.First(&stat, "user_id = ?", user.ID).Error)
	require.Zero(t, stat.MakeupCardsEarned)
	require.Equal(t, 2, stat.MakeupCardsGranted)
	var count int64
	require.NoError(t, db.Model(&models.AppSchemaMigration{}).Where("version = ?", models.CheckInMakeupCardScheduleMigrationVersion).Count(&count).Error)
	require.Zero(t, count)
	require.NoError(t, db.Callback().Create().Remove("test:reject_weekly_marker"))
	require.NoError(t, models.EnsureCheckInSchema(db))
	require.NoError(t, db.First(&stat, "user_id = ?", user.ID).Error)
	require.Equal(t, 1, stat.MakeupCardsEarned)
	require.Equal(t, 2, stat.MakeupCardsGranted)
}

func TestMakeupCardScheduleMigrationPreservesPreviouslyIssuedWeeklyCards(t *testing.T) {
	db := newCheckInTestDB(t)
	user := createCheckInTestUser(t, db, "checkin-migration-weekly-retained")
	start := time.Date(2026, 7, 1, 9, 0, 0, 0, time.FixedZone("CST", 8*3600))
	for day := 1; day <= 14; day++ {
		require.NoError(t, db.Create(&models.CheckIn{
			UserID: user.ID, CheckInDate: checkInDateOnly(start.AddDate(0, 0, day-1)),
			StreakDays: day, ExpEarned: 1, IsMakeup: day == 4,
		}).Error)
	}
	require.NoError(t, db.Create(&models.UserCheckInStat{
		UserID: user.ID, MakeupCardsEarned: 2, MakeupCardsGranted: 2, MakeupCardsUsed: 1,
	}).Error)
	require.NoError(t, db.Create(&models.AppSchemaMigration{
		Version: "20261025_03_checkin_weekly_makeup_cards", AppliedAt: time.Now(),
	}).Error)
	require.NoError(t, db.Where("version = ?", models.CheckInMakeupCardScheduleMigrationVersion).Delete(&models.AppSchemaMigration{}).Error)
	service := NewCheckInService(db)
	for range 2 {
		require.NoError(t, models.EnsureCheckInSchema(db))
		rebuilt, err := service.RebuildUserStats(user.ID)
		require.NoError(t, err)
		require.Equal(t, 1, rebuilt.MakeupCardsEarned)
		require.Equal(t, 3, rebuilt.MakeupCardsGranted)
		require.Equal(t, 1, rebuilt.MakeupCardsUsed)
		status, err := service.Status(user.ID, start.AddDate(0, 0, 14))
		require.NoError(t, err)
		require.Equal(t, 3, status.MakeupCards)
	}
	for day := 15; day <= 21; day++ {
		result, err := service.CheckIn(user.ID, start.AddDate(0, 0, day-1))
		require.NoError(t, err)
		if day < 21 {
			require.Zero(t, result.MakeupCardsAwarded)
			require.Equal(t, 3, result.MakeupCards)
		} else {
			require.Equal(t, 1, result.MakeupCardsAwarded)
			require.Equal(t, 4, result.MakeupCards)
		}
	}
	rebuilt, err := service.RebuildUserStats(user.ID)
	require.NoError(t, err)
	require.Equal(t, 2, rebuilt.MakeupCardsEarned)
	require.Equal(t, 3, rebuilt.MakeupCardsGranted)
	require.Equal(t, 1, rebuilt.MakeupCardsUsed)
}

func TestCheckInCompensationClaimIsIdempotent(t *testing.T) {
	db := newCheckInTestDB(t)
	user := createCheckInTestUser(t, db, "checkin-compensation")
	service := NewCheckInCompensationService(db)
	loc := time.FixedZone("CST", 8*3600)
	now := time.Date(2026, 7, 16, 11, 0, 0, 0, loc)
	compensatedDate := time.Date(2026, 7, 12, 0, 0, 0, 0, time.UTC)

	campaign, err := service.PublishCampaign(CheckInCompensationCampaignInput{
		Title: "签到异常补偿", Description: "测试活动", ClaimStartDate: now, ClaimEndDate: now,
		CreatedBy: 99,
		Targets:   []CheckInCompensationTarget{{UserID: user.ID, CheckInDate: compensatedDate, ExpReward: 42, Reason: "客户端异常"}},
	}, now)
	require.NoError(t, err)

	first, err := service.Claim(user.ID, campaign.ID, compensatedDate, now)
	require.NoError(t, err)
	require.False(t, first.Already)
	require.Equal(t, 42, first.ExpReward)
	require.Equal(t, 52, first.TotalExp)

	retry, err := service.Claim(user.ID, campaign.ID, compensatedDate, now)
	require.NoError(t, err)
	require.True(t, retry.Already)
	require.Equal(t, 42, retry.ExpReward)
	require.Equal(t, 52, retry.TotalExp)

	items, err := service.ListForUser(user.ID)
	require.NoError(t, err)
	require.Len(t, items, 1)
	require.True(t, items[0].Claimed)

	var claimCount, ledgerCount int64
	require.NoError(t, db.Model(&models.CheckInCompensationClaim{}).Where("user_id = ?", user.ID).Count(&claimCount).Error)
	require.NoError(t, db.Model(&models.UserExperienceLedger{}).Where("user_id = ? AND source_type = ?", user.ID, "checkin_compensation").Count(&ledgerCount).Error)
	require.Equal(t, int64(1), claimCount)
	require.Equal(t, int64(1), ledgerCount)
}

func newCheckInTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+stringsForCheckInDB(t.Name())+"?mode=memory&cache=shared"), &gorm.Config{TranslateError: true})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&models.User{}, &models.CheckIn{}, &models.UserCheckInStat{}, &models.CheckInRepairLog{},
		&models.CheckInCompensationCampaign{}, &models.CheckInCompensationEligibility{}, &models.CheckInCompensationClaim{},
		&models.UserExperienceLedger{},
	))
	require.NoError(t, models.EnsureCheckInSchema(db))
	return db
}

func createCheckInTestUser(t *testing.T, db *gorm.DB, studentID string) models.User {
	t.Helper()
	user := models.User{StudentID: studentID, PasswordHash: "test-password", Nickname: studentID, Exp: 10}
	require.NoError(t, db.Create(&user).Error)
	return user
}

func stringsForCheckInDB(value string) string {
	replacer := strings.NewReplacer("/", "_", " ", "_")
	return replacer.Replace(value)
}
