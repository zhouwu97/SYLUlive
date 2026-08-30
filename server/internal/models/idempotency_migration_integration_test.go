//go:build integration

package models

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

func TestIdempotencySchemaUpgradeFromLegacyFixtures(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_DSN")
	if dsn == "" {
		t.Skip("未配置 TEST_DATABASE_DSN，跳过 PostgreSQL 迁移集成测试")
	}

	for _, fixture := range []string{
		"idempotency_legacy.sql",
		"idempotency_current_minus_one.sql",
	} {
		t.Run(fixture, func(t *testing.T) {
			db, cleanup := openIdempotencyMigrationDB(t, dsn)
			defer cleanup()

			path := migrationFixturePath(t, fixture)
			source, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("读取迁移夹具失败: %v", err)
			}
			if err := db.Exec(string(source)).Error; err != nil {
				t.Fatalf("执行旧库夹具失败: %v", err)
			}
			before := readMigrationFixtureCounts(t, db)
			if err := EnsureIdempotencySchema(db); err != nil {
				t.Fatalf("升级旧库失败: %v", err)
			}
			if err := EnsureIdempotencySchema(db); err != nil {
				t.Fatalf("重复执行迁移失败: %v", err)
			}
			after := readMigrationFixtureCounts(t, db)
			if before != after {
				t.Fatalf("迁移破坏了旧业务数据: before=%+v after=%+v", before, after)
			}

			record := IdempotencyRecord{
				Scope: "user:1", Key: "fixture-key", Method: "POST", Path: "/api/test",
				RequestHash: "fixture-hash", State: IdempotencyStateCompleted,
				ResponseCode: 201, ContentType: "application/json", ResponseBody: []byte(`{"ok":true}`),
				ExpiresAt: time.Now().UTC().Add(time.Hour),
			}
			if err := db.Create(&record).Error; err != nil {
				t.Fatalf("写入升级后的记录失败: %v", err)
			}
			duplicate := record
			duplicate.ID = 0
			if err := db.Create(&duplicate).Error; err == nil {
				t.Fatal("升级后唯一约束未阻止同范围同键重复记录")
			}
		})
	}
}

type migrationFixtureCounts struct {
	users       int64
	posts       int64
	postTopics  int64
	postContent string
}

func readMigrationFixtureCounts(t *testing.T, db *gorm.DB) migrationFixtureCounts {
	t.Helper()
	var counts migrationFixtureCounts
	if err := db.Table("migration_fixture_users").Count(&counts.users).Error; err != nil {
		t.Fatalf("统计旧用户数据失败: %v", err)
	}
	if err := db.Table("migration_fixture_posts").Count(&counts.posts).Error; err != nil {
		t.Fatalf("统计旧帖子数据失败: %v", err)
	}
	if err := db.Table("migration_fixture_post_topics").Count(&counts.postTopics).Error; err != nil {
		t.Fatalf("统计旧帖子关系失败: %v", err)
	}
	var post struct {
		Content string
	}
	if err := db.Table("migration_fixture_posts").Select("content").Where("id = ?", 10).Scan(&post).Error; err != nil {
		t.Fatalf("读取旧帖子内容失败: %v", err)
	}
	counts.postContent = post.Content
	return counts
}

func openIdempotencyMigrationDB(t *testing.T, dsn string) (*gorm.DB, func()) {
	t.Helper()
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开 PostgreSQL 迁移数据库失败: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("读取 PostgreSQL 连接失败: %v", err)
	}
	// SET search_path 是连接级设置；迁移夹具固定单连接，保证所有语句落在隔离 schema。
	sqlDB.SetMaxOpenConns(1)
	sqlDB.SetMaxIdleConns(1)
	if err := sqlDB.Ping(); err != nil {
		t.Fatalf("连接 PostgreSQL 迁移数据库失败: %v", err)
	}
	schema := fmt.Sprintf("idempotency_migration_%d", time.Now().UnixNano())
	if err := db.Exec("CREATE SCHEMA " + schema).Error; err != nil {
		t.Fatalf("创建迁移 schema 失败: %v", err)
	}
	if err := db.Exec("SET search_path TO " + schema + ", public").Error; err != nil {
		t.Fatalf("设置迁移 schema 失败: %v", err)
	}
	return db, func() {
		_ = db.Exec("DROP SCHEMA " + schema + " CASCADE").Error
		_ = sqlDB.Close()
	}
}

func migrationFixturePath(t *testing.T, name string) string {
	t.Helper()
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("定位迁移集成测试源文件失败")
	}
	return filepath.Join(filepath.Dir(sourceFile), "..", "..", "testdata", "migrations", name)
}
