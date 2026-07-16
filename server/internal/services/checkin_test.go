package services

import (
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
	require.Equal(t, 1, secondDay.ExpEarned)

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

	rebuilt, err := models.RebuildUserCheckInStats(db, user.ID)
	require.NoError(t, err)
	require.Equal(t, 3, rebuilt.CurrentStreak)
	require.Equal(t, 3, rebuilt.LongestStreak)

	var refreshed models.User
	require.NoError(t, db.First(&refreshed, user.ID).Error)
	require.Equal(t, 10, refreshed.Exp)
	require.Equal(t, "2026-07-15", refreshed.LastCheckInDate)

	var records []models.CheckIn
	require.NoError(t, db.Where("user_id = ?", user.ID).Order("check_in_date ASC").Find(&records).Error)
	require.Equal(t, []int{1, 2, 1, 2, 3}, []int{records[0].StreakDays, records[1].StreakDays, records[2].StreakDays, records[3].StreakDays, records[4].StreakDays})
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
