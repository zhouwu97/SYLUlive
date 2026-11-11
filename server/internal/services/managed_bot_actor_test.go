package services

import (
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"sync"
	"testing"
)

func TestIntegrationBotActorIndependentPostgresNumbering(t *testing.T) {
	db := integrationTestDB(t)
	if db.Dialector.Name() != "postgres" {
		t.Skip("independent numbering uses production PostgreSQL sequences")
	}
	human := models.User{Nickname: "合成注册者", PasswordHash: "synthetic", AccountStatus: "active"}
	require.NoError(t, db.Create(&human).Error)
	var wg sync.WaitGroup
	ids := make(chan uint, 4)
	errs := make(chan error, 4)
	for range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			actor := models.User{Nickname: "合成AI", PasswordHash: "synthetic", AccountStatus: "bot"}
			err := db.Transaction(func(tx *gorm.DB) error { return createManagedBotActor(tx, &actor) })
			ids <- actor.ID
			errs <- err
		}()
	}
	wg.Wait()
	close(ids)
	close(errs)
	for err := range errs {
		require.NoError(t, err)
	}
	seen := map[uint]bool{}
	for id := range ids {
		require.Greater(t, uint64(id), managedBotActorIDBase)
		require.False(t, seen[id])
		seen[id] = true
	}
	next := models.User{Nickname: "合成下一注册者", PasswordHash: "synthetic", AccountStatus: "active"}
	require.NoError(t, db.Create(&next).Error)
	require.Equal(t, human.ID+1, next.ID, "新建AI不应消耗用户注册编号")
}
