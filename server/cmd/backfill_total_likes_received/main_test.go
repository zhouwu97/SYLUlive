package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"shenliyuan/internal/models"
)

func snapshotTestDB(t *testing.T) (*gorm.DB, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "likes.db")
	db, err := gorm.Open(sqlite.Open(path), &gorm.Config{})
	require.NoError(t, err)
	pool, err := db.DB()
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, pool.Close()) })
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.Post{}, &models.Reply{}, &models.Like{}))
	require.NoError(t, db.Create(&[]models.User{
		{ID: 1, PasswordHash: "fixture", TotalLikesReceived: 122},
		{ID: 2, PasswordHash: "fixture", TotalLikesReceived: 99},
		{ID: 3, PasswordHash: "fixture", AccountStatus: "cancelled", TotalLikesReceived: 5},
	}).Error)
	require.NoError(t, db.Create(&[]models.Post{
		{ID: 1, AuthorID: 1, BoardID: models.BoardShuitie},
		{ID: 2, AuthorID: 2, BoardID: models.BoardShuitie, Status: models.PostStatusDeleted},
	}).Error)
	require.NoError(t, db.Create(&models.Reply{ID: 1, AuthorID: 2, PostID: 1}).Error)
	require.NoError(t, db.Create(&[]models.Like{
		{UserID: 2, TargetType: "post", TargetID: 1},
		{UserID: 1, TargetType: "post", TargetID: 1},
		{UserID: 3, TargetType: "post", TargetID: 1},
		{UserID: 1, TargetType: "post", TargetID: 2},
		{UserID: 2, TargetType: "reply", TargetID: 1},
	}).Error)
	return db, path
}

func snapshotStoredCounts(t *testing.T, db *gorm.DB) []int {
	t.Helper()
	var counts []int
	require.NoError(t, db.Table("users").Order("id").Pluck("total_likes_received", &counts).Error)
	return counts
}

func TestSnapshotDefaultPreviewAndExplicitApply(t *testing.T) {
	db, path := snapshotTestDB(t)
	var output bytes.Buffer
	err := run(context.Background(), []string{"-driver", "sqlite"}, func(key string) string {
		require.Equal(t, "RECEIVED_LIKES_BACKFILL_DSN", key)
		return path
	}, &output)
	require.NoError(t, err)
	require.Contains(t, output.String(), `"applied":false`)
	require.Contains(t, output.String(), `"before":122,"after":1`)
	require.Equal(t, []int{122, 99, 5}, snapshotStoredCounts(t, db))
	report, err := rebuildSnapshot(context.Background(), db, true)
	require.NoError(t, err)
	require.Equal(t, 3, report.Changed)
	require.Equal(t, []int{1, 0, 0}, snapshotStoredCounts(t, db))
	report, err = rebuildSnapshot(context.Background(), db, true)
	require.NoError(t, err)
	require.Zero(t, report.Changed, "重复执行不得重复扣减")
	var likes int64
	require.NoError(t, db.Model(&models.Like{}).Count(&likes).Error)
	require.EqualValues(t, 5, likes, "校准不能删除点赞事实")
}

func TestSnapshotFailureRollsBackAndRequiresExplicitConnection(t *testing.T) {
	db, _ := snapshotTestDB(t)
	updates := 0
	require.NoError(t, db.Callback().Update().Before("gorm:update").Register("snapshot_fail", func(tx *gorm.DB) {
		updates++
		if updates == 2 {
			tx.AddError(errors.New("synthetic update failure"))
		}
	}))
	_, err := rebuildSnapshot(context.Background(), db, true)
	require.ErrorContains(t, err, "synthetic update failure")
	require.Equal(t, []int{122, 99, 5}, snapshotStoredCounts(t, db), "中途失败整批回滚")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = rebuildSnapshot(ctx, db, true)
	require.ErrorIs(t, err, context.Canceled)
	err = run(context.Background(), nil, func(string) string { return "" }, &bytes.Buffer{})
	require.ErrorContains(t, err, "请显式设置 RECEIVED_LIKES_BACKFILL_DSN")
}

func TestSnapshotPostgresApplyRollbackAndLockTimeout(t *testing.T) {
	dsn := os.Getenv("INTEGRATION_TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("需要本机专用 PostgreSQL")
	}
	cfg, err := pgx.ParseConfig(dsn)
	require.NoError(t, err)
	require.Equal(t, "127.0.0.1", cfg.Host)
	require.Equal(t, "sylulive_integration_test", cfg.Database)
	require.Empty(t, cfg.Fallbacks)
	root, err := gorm.Open(postgres.Open(dsn), &gorm.Config{Logger: logger.Discard})
	require.NoError(t, err)
	schema := "likes_snapshot_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	require.NoError(t, root.Exec("CREATE SCHEMA "+schema).Error)
	t.Cleanup(func() {
		require.NoError(t, root.Exec("DROP SCHEMA "+schema+" CASCADE").Error)
		pool, err := root.DB()
		require.NoError(t, err)
		require.NoError(t, pool.Close())
	})
	db, err := gorm.Open(postgres.Open(dsn+" search_path="+schema), &gorm.Config{Logger: logger.Discard})
	require.NoError(t, err)
	pool, err := db.DB()
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, pool.Close()) })
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.Post{}, &models.Reply{}, &models.Like{}))
	require.NoError(t, db.Create(&[]models.User{{ID: 1, PasswordHash: "fixture", TotalLikesReceived: 122}, {ID: 2, PasswordHash: "fixture", TotalLikesReceived: 5}}).Error)
	require.NoError(t, db.Create(&models.Post{ID: 1, AuthorID: 1, BoardID: models.BoardShuitie}).Error)
	require.NoError(t, db.Create(&models.Like{UserID: 2, TargetType: "post", TargetID: 1}).Error)
	report, err := rebuildSnapshot(context.Background(), db, false)
	require.NoError(t, err)
	require.Equal(t, 2, report.Changed)
	require.Equal(t, []int{122, 5}, snapshotStoredCounts(t, db))

	// 显式写入等待在途写事务；超时必须回滚并释放自己的事务。
	holder := db.Begin()
	require.NoError(t, holder.Error)
	defer holder.Rollback()
	require.NoError(t, holder.Exec("UPDATE users SET total_likes_received = 122 WHERE id = 1").Error)
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	_, err = rebuildSnapshot(ctx, db, true)
	cancel()
	require.Error(t, err)
	require.NoError(t, holder.Rollback().Error)
	require.Equal(t, []int{122, 5}, snapshotStoredCounts(t, db))

	report, err = rebuildSnapshot(context.Background(), db, true)
	require.NoError(t, err)
	require.True(t, report.Applied)
	require.Equal(t, []int{1, 0}, snapshotStoredCounts(t, db))
	report, err = rebuildSnapshot(context.Background(), db, true)
	require.NoError(t, err)
	require.Zero(t, report.Changed)

	require.NoError(t, db.Exec("UPDATE users SET total_likes_received = 99").Error)
	require.NoError(t, db.Exec(`CREATE FUNCTION fail_likes_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.id = 2 THEN RAISE EXCEPTION 'synthetic update failure'; END IF; RETURN NEW; END $$`).Error)
	require.NoError(t, db.Exec("CREATE TRIGGER fail_likes_snapshot BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION fail_likes_snapshot()").Error)
	_, err = rebuildSnapshot(context.Background(), db, true)
	require.ErrorContains(t, err, "synthetic update failure")
	require.Equal(t, []int{99, 99}, snapshotStoredCounts(t, db))
}
