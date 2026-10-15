//go:build integration

package handlers

import (
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

func TestPostgresEmailResetRecovery(t *testing.T) {
	dsn, ok := postgresIntegrationDSN(t, "缺少独立 PostgreSQL 测试库")
	if !ok {
		return
	}
	if os.Getenv("ALLOW_DESTRUCTIVE_INTEGRATION_TESTS") != "1" {
		requireIntegrationEnv(t, "未允许可丢弃测试库写入")
		return
	}
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	t.Cleanup(func() { _ = sqlDB.Close() })
	var dbName string
	require.NoError(t, db.Raw("SELECT current_database()").Scan(&dbName).Error)
	require.True(t, strings.HasSuffix(strings.ToLower(dbName), "_test"), "拒绝写入非测试数据库")
	// 每次只写入一个新 schema，不清理已有测试表。名称由服务端 UUID 生成。
	schema := "auth_remediation_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	require.NoError(t, db.Exec(`CREATE SCHEMA "`+schema+`"`).Error)
	t.Cleanup(func() { _ = db.Exec(`DROP SCHEMA IF EXISTS "` + schema + `" CASCADE`).Error })
	isolatedDSN := dsn + " search_path=" + schema
	if strings.HasPrefix(dsn, "postgres://") || strings.HasPrefix(dsn, "postgresql://") {
		parsed, err := url.Parse(dsn)
		require.NoError(t, err)
		query := parsed.Query()
		query.Set("search_path", schema)
		parsed.RawQuery = query.Encode()
		isolatedDSN = parsed.String()
	}
	isolated, err := gorm.Open(postgres.Open(isolatedDSN), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	require.NoError(t, err)
	isolatedSQL, err := isolated.DB()
	require.NoError(t, err)
	t.Cleanup(func() { _ = isolatedSQL.Close() })
	h, fixtureDB, user, mailer := remediationAuthFixtureForDB(t, isolated)
	testEmailResetRecovery(t, h, fixtureDB, user, mailer)
}
