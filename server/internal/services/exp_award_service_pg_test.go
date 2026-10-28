//go:build integration

package services

import (
	"io"
	"log"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"
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
	sqlDB, err := db.DB()
	require.NoError(t, err)
	t.Cleanup(func() { _ = sqlDB.Close() })
	if os.Getenv("ALLOW_DESTRUCTIVE_INTEGRATION_TESTS") != "1" {
		requireIntegrationEnv(t, "ALLOW_DESTRUCTIVE_INTEGRATION_TESTS 未显式开启，跳过经验奖励 PostgreSQL 幂等测试")
	}
	var dbName string
	require.NoError(t, db.Raw("SELECT current_database()").Scan(&dbName).Error)
	require.True(t, strings.HasSuffix(strings.ToLower(dbName), "_test"),
		"拒绝在非 *_test 数据库上执行经验奖励集成测试：%s", dbName)
	// 其他集成夹具会重置 users 的序列，不能复用上轮残留的同 user_id 奖励流水。
	schema := "exp_award_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	require.NoError(t, db.Exec(`CREATE SCHEMA "`+schema+`"`).Error)
	t.Cleanup(func() { require.NoError(t, db.Exec(`DROP SCHEMA IF EXISTS "`+schema+`" CASCADE`).Error) })
	isolatedDSN := dsn + " search_path=" + schema
	if strings.HasPrefix(dsn, "postgres://") || strings.HasPrefix(dsn, "postgresql://") {
		parsed, err := url.Parse(dsn)
		require.NoError(t, err)
		query := parsed.Query()
		query.Set("search_path", schema)
		parsed.RawQuery = query.Encode()
		isolatedDSN = parsed.String()
	}
	isolated, err := gorm.Open(postgres.Open(isolatedDSN), &gorm.Config{Logger: quiet})
	require.NoError(t, err)
	isolatedSQL, err := isolated.DB()
	require.NoError(t, err)
	t.Cleanup(func() { _ = isolatedSQL.Close() })
	require.NoError(t, isolated.AutoMigrate(
		&models.User{},
		&models.ExpLog{},
		&models.WaterSectionExpLog{},
		&models.WaterSectionUserStat{},
		&models.WaterSectionLevelTitle{},
	))
	return isolated
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
