package tasks

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/clients"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func TestCampusSyncSharedRound(t *testing.T) {
	dsn := filepath.Join(t.TempDir(), "campus.db") + "?_pragma=busy_timeout(5000)"
	dbA, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	require.NoError(t, err)
	dbB, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	require.NoError(t, err)
	for _, db := range []*gorm.DB{dbA, dbB} {
		pool, err := db.DB()
		require.NoError(t, err)
		t.Cleanup(func() { require.NoError(t, pool.Close()) })
	}
	testCampusSyncRound(t, dbA, dbB)
}

func testCampusSyncRound(t *testing.T, dbA, dbB *gorm.DB) {
	require.NoError(t, dbA.AutoMigrate(&models.CampusArticle{}, &models.JWCSyncState{}, &models.CampusSyncSchedule{}))
	var calls atomic.Int32
	spec := services.CrawlSourceSpec{Source: "jwc", CrawlFunc: func(ctx context.Context, _ map[string][]string, _ int, _ bool) (*clients.CrawlResponse, error) {
		calls.Add(1)
		return nil, errors.New("测试来源暂时不可用")
	}}
	a, b := services.NewCampusSyncService(dbA, spec), services.NewCampusSyncService(dbB, spec)
	var wg sync.WaitGroup
	for _, svc := range []*services.CampusSyncService{a, b} {
		wg.Add(1)
		go func() { defer wg.Done(); svc.SyncScheduled(context.Background(), time.Hour, false) }()
	}
	wg.Wait()
	require.EqualValues(t, 1, calls.Load())
	require.Nil(t, b.SyncScheduled(context.Background(), time.Hour, false))
	require.NotNil(t, b.SyncScheduled(context.Background(), time.Hour, true))
	require.Nil(t, a.SyncScheduled(context.Background(), time.Hour, true))
	require.EqualValues(t, 2, calls.Load())
	spec.Source = "cxcy"
	require.NotNil(t, services.NewCampusSyncService(dbB, spec).SyncScheduled(context.Background(), time.Hour, false))
	require.EqualValues(t, 3, calls.Load())
}
