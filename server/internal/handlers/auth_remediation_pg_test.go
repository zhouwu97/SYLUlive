//go:build integration

package handlers

import (
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"shenliyuan/internal/models"
)

func TestPostgresEmailResetRecovery(t *testing.T) {
	isolated := remediationPostgresDB(t)
	h, fixtureDB, user, mailer := remediationAuthFixtureForDB(t, isolated)
	t.Run("throttle_query_failure", func(t *testing.T) {
		testLoginThrottleQueryFailurePreservesMemoryLock(t, h, fixtureDB, user)
	})
	testEmailResetRecovery(t, h, fixtureDB, user, mailer)
}

func TestPostgresLoginThrottleConcurrentFirstFailures(t *testing.T) {
	db := remediationPostgresDB(t)
	require.NoError(t, db.AutoMigrate(&models.LoginThrottleRecord{}))
	sqlDB, err := db.DB()
	require.NoError(t, err)
	const workers = 16
	sqlDB.SetMaxOpenConns(workers + 4)
	ready := make(chan struct{}, workers)
	release := make(chan struct{})
	require.NoError(t, db.Callback().Create().Before("gorm:create").Register("test:concurrent-first-failures", func(tx *gorm.DB) {
		if tx.Statement.Table == "login_throttle_records" {
			ready <- struct{}{}
			<-release
		}
	}))
	h := &AuthHandler{db: db}
	scope := loginThrottleScope("account", t.Name())
	clearLoginFailures(scope)
	t.Cleanup(func() { clearLoginFailures(scope) })
	now := time.Now()
	var group sync.WaitGroup
	for i := 0; i < workers; i++ {
		group.Go(func() { h.registerLoginFailure(scope, now) })
	}
	timer := time.NewTimer(10 * time.Second)
	defer timer.Stop()
	for i := 0; i < workers; i++ {
		select {
		case <-ready:
		case <-timer.C:
			close(release)
			group.Wait()
			t.Fatal("并发请求没有全部进入首次计数窗口")
		}
	}
	close(release)
	group.Wait()
	var record models.LoginThrottleRecord
	require.NoError(t, db.Where("scope = ?", scope).First(&record).Error)
	require.Equal(t, workers, record.FailureCount, "跨实例保护不能把唯一键冲突丢给单进程回退")
}

func remediationPostgresDB(t *testing.T) *gorm.DB {
	t.Helper()
	dsn, ok := postgresIntegrationDSN(t, "缺少独立 PostgreSQL 测试库")
	if !ok {
		return nil
	}
	if os.Getenv("ALLOW_DESTRUCTIVE_INTEGRATION_TESTS") != "1" {
		requireIntegrationEnv(t, "未允许可丢弃测试库写入")
		return nil
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
	return isolated
}
