//go:build integration

package services

import (
	"io"
	"log"
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"shenliyuan/internal/academiccalendar"
	"shenliyuan/internal/models"
)

func openExpAwardPG(t *testing.T) *gorm.DB {
	t.Helper()
	require.NoError(t, academiccalendar.InitializeTimezone())
	dsn := strings.TrimSpace(os.Getenv("TEST_DATABASE_DSN"))
	if dsn == "" {
		requireIntegrationEnv(t, "TEST_DATABASE_DSN 未设置，跳过经验奖励 PostgreSQL 幂等测试")
	}
	quiet := logger.New(log.New(io.Discard, "", 0), logger.Config{
		SlowThreshold:             0,
		LogLevel:                  logger.Error,
		IgnoreRecordNotFoundError: true,
	})
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{Logger: quiet})
	require.NoError(t, err)
	if os.Getenv("ALLOW_DESTRUCTIVE_INTEGRATION_TESTS") != "1" {
		t.Skip("ALLOW_DESTRUCTIVE_INTEGRATION_TESTS 未显式开启，跳过经验奖励 PostgreSQL 幂等测试")
	}
	var dbName string
	require.NoError(t, db.Raw("SELECT current_database()").Scan(&dbName).Error)
	require.True(t, strings.HasSuffix(strings.ToLower(dbName), "_test"),
		"拒绝在非 *_test 数据库上执行经验奖励集成测试：%s", dbName)
	require.NoError(t, db.AutoMigrate(
		&models.User{},
		&models.ExpLog{},
		&models.WaterSectionExpLog{},
		&models.WaterSectionUserStat{},
		&models.WaterSectionLevelTitle{},
	))
	return db
}

func TestAwardDailyGlobalExpPostgresIsIdempotent(t *testing.T) {
	db := openExpAwardPG(t)
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
}

func TestAwardDailySectionExpPostgresIsIdempotent(t *testing.T) {
	db := openExpAwardPG(t)
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
}
