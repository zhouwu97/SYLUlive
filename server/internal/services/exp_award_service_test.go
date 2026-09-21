package services

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"shenliyuan/internal/academiccalendar"
	"shenliyuan/internal/models"
)

func openExpAwardTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	require.NoError(t, academiccalendar.InitializeTimezone())
	dsn := "file:exp_award_" + strings.NewReplacer("/", "_", "\\", "_").Replace(t.Name()) + "?mode=memory&cache=shared"
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{TranslateError: true})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&models.User{},
		&models.ExpLog{},
		&models.WaterSectionExpLog{},
		&models.WaterSectionUserStat{},
		&models.WaterSectionLevelTitle{},
	))
	return db
}

func TestAwardDailyGlobalExpIsIdempotent(t *testing.T) {
	db := openExpAwardTestDB(t)
	user := models.User{PasswordHash: "test"}
	require.NoError(t, db.Create(&user).Error)

	awarded, _, err := AwardDailyGlobalExp(db, user.ID, GlobalActionReplyDaily, GlobalExpReplyDaily, "reply", 1)
	require.NoError(t, err)
	require.True(t, awarded)

	awarded, _, err = AwardDailyGlobalExp(db, user.ID, GlobalActionReplyDaily, GlobalExpReplyDaily, "reply", 2)
	require.NoError(t, err)
	require.False(t, awarded)

	var stored models.User
	require.NoError(t, db.First(&stored, user.ID).Error)
	require.Equal(t, GlobalExpReplyDaily, stored.Exp)
	var logCount int64
	require.NoError(t, db.Model(&models.ExpLog{}).Where("user_id = ?", user.ID).Count(&logCount).Error)
	require.EqualValues(t, 1, logCount)
}

func TestAwardDailySectionExpIsIdempotent(t *testing.T) {
	db := openExpAwardTestDB(t)
	user := models.User{PasswordHash: "test"}
	require.NoError(t, db.Create(&user).Error)

	awarded, _, err := AwardDailySectionExp(db, user.ID, 7, "water", "水帖", GlobalActionReplyDaily, GlobalExpReplyDaily, "reply", 1)
	require.NoError(t, err)
	require.True(t, awarded)

	awarded, _, err = AwardDailySectionExp(db, user.ID, 7, "water", "水帖", GlobalActionReplyDaily, GlobalExpReplyDaily, "reply", 2)
	require.NoError(t, err)
	require.False(t, awarded)

	var stat models.WaterSectionUserStat
	require.NoError(t, db.Where("user_id = ? AND section_id = ?", user.ID, 7).First(&stat).Error)
	require.Equal(t, GlobalExpReplyDaily, stat.Exp)
	require.Equal(t, 1, stat.ReplyCount)
	var logCount int64
	require.NoError(t, db.Model(&models.WaterSectionExpLog{}).Where("user_id = ? AND section_id = ?", user.ID, 7).Count(&logCount).Error)
	require.EqualValues(t, 1, logCount)
}
