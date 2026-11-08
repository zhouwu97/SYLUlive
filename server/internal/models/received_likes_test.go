package models

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

type receivedLikesQueryLog struct {
	logger.Interface
	mu         sync.Mutex
	aggregates int
}

func (l *receivedLikesQueryLog) Trace(ctx context.Context, begin time.Time, fc func() (string, int64), err error) {
	sql, _ := fc()
	if strings.Contains(strings.ToLower(sql), "count(*) as total") {
		l.mu.Lock()
		l.aggregates++
		l.mu.Unlock()
	}
	l.Interface.Trace(ctx, begin, fc, err)
}

func newReceivedLikeModelDB(t *testing.T) (*gorm.DB, *receivedLikesQueryLog) {
	t.Helper()
	l := &receivedLikesQueryLog{Interface: logger.Default.LogMode(logger.Silent)}
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{Logger: l})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	t.Cleanup(func() { require.NoError(t, sqlDB.Close()) })
	require.NoError(t, db.AutoMigrate(&User{}, &Post{}, &Reply{}, &Like{}))
	for i := uint(1); i <= 20; i++ {
		require.NoError(t, db.Create(&User{ID: i, TotalLikesReceived: 122, PasswordHash: "fixture"}).Error)
		require.NoError(t, db.Create(&Post{ID: i, AuthorID: i, BoardID: BoardShuitie, Status: PostStatusNormal}).Error)
		if i%2 == 1 {
			require.NoError(t, db.Create(&Like{UserID: 20, TargetType: "post", TargetID: i}).Error)
		}
	}
	return db, l
}

func TestReceivedLikeCountsBatchAndAuthorPreload(t *testing.T) {
	db, log := newReceivedLikeModelDB(t)
	require.NoError(t, db.AutoMigrate(&Like{}))
	require.True(t, db.Migrator().HasIndex(&Like{}, "idx_like_unique"))
	require.True(t, db.Migrator().HasIndex(&Like{}, "idx_like_target"))
	var users []User
	require.NoError(t, db.Order("id").Find(&users).Error)
	require.Len(t, users, 20)
	require.Equal(t, 1, log.aggregates, "整个用户批次只汇总一次")
	for _, user := range users {
		require.Equal(t, int(user.ID%2), user.TotalLikesReceived)
	}
	var pointers []*User
	require.NoError(t, db.Order("id").Find(&pointers).Error)
	require.Equal(t, 2, log.aggregates)
	for _, user := range pointers {
		require.Equal(t, int(user.ID%2), user.TotalLikesReceived)
	}
	var posts []Post
	require.NoError(t, db.Preload("Author").Order("id").Find(&posts).Error)
	require.Equal(t, 3, log.aggregates, "Author 预载同样只汇总一次")
	for _, post := range posts {
		require.Equal(t, int(post.AuthorID%2), post.Author.TotalLikesReceived)
	}
	var stored int
	require.NoError(t, db.Table("users").Where("id = ?", 1).Pluck("total_likes_received", &stored).Error)
	require.Equal(t, 122, stored, "普通读取不能偷偷改写兼容列")
}

func TestReceivedLikeProjectionHonorsSelectedColumns(t *testing.T) {
	db, log := newReceivedLikeModelDB(t)
	for _, test := range []struct {
		name          string
		query         *gorm.DB
		want, queries int
	}{
		{"omit unrelated", db.Omit("password_hash"), 1, 1},
		{"select total", db.Select("id", "total_likes_received"), 1, 1},
		{"select id only", db.Select("id"), 0, 0},
		{"omit total", db.Omit("total_likes_received"), 0, 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			before := log.aggregates
			var user User
			require.NoError(t, test.query.First(&user, 1).Error)
			require.Equal(t, test.want, user.TotalLikesReceived)
			require.Equal(t, test.queries, log.aggregates-before)
		})
	}
}

func TestReceivedLikeProjectionTransactionAndFailure(t *testing.T) {
	db, _ := newReceivedLikeModelDB(t)
	tx := db.Begin()
	require.NoError(t, tx.Error)
	require.NoError(t, tx.Create(&Like{UserID: 20, TargetType: "post", TargetID: 2}).Error)
	var user User
	require.NoError(t, tx.First(&user, 2).Error)
	require.Equal(t, 1, user.TotalLikesReceived, "读取必须看到同一事务内的点赞")
	require.NoError(t, tx.Rollback().Error)
	require.NoError(t, db.First(&user, 2).Error)
	require.Zero(t, user.TotalLikesReceived)
	_, err := ReceivedLikeCounts(db, nil)
	require.NoError(t, err)
	counts, err := ReceivedLikeCounts(db, []uint{0, 1, 1, 999})
	require.NoError(t, err)
	require.Equal(t, map[uint]int{1: 1, 999: 0}, counts)
	require.NoError(t, db.Migrator().DropTable(&Reply{}))
	require.Error(t, db.First(&user, 2).Error, "汇总失败必须报错，不能继续返回旧值")
}
