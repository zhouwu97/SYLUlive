package services

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
)

func TestIntegrationManagedBotAdditiveMigrationPreservesExistingBinding(t *testing.T) {
	db, service, binding, _ := integrationActionFixture(t)
	require.NoError(t, db.First(&binding, "id = ?", binding.ID).Error)
	before := binding
	// The deployed schema has no managed_bots table. Apply the same additive model
	// migration twice, retaining all existing account and authorization records.
	for i := 0; i < 2; i++ {
		require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
	}
	require.NoError(t, db.First(&binding, "id = ?", before.ID).Error)
	require.Equal(t, before, binding)
	var bots int64
	require.NoError(t, db.Model(&models.ManagedBot{}).Count(&bots).Error)
	require.Zero(t, bots, "migration must not create a robot on the owner's behalf")
	name := "迁移验收机器人"
	bot, err := service.UpdateManagedBot(context.Background(), 1, ManagedBotUpdate{Name: &name, Enabled: false})
	require.NoError(t, err)
	require.False(t, bot.Enabled)
	var owner models.User
	require.NoError(t, db.First(&owner, 1).Error)
	require.Equal(t, "active", owner.AccountStatus)
	require.Equal(t, "synthetic", owner.PasswordHash)
	require.NoError(t, db.First(&binding, "id = ?", before.ID).Error)
	require.Equal(t, before.Scopes, binding.Scopes)
	require.Equal(t, before.Epoch, binding.Epoch)
	require.Equal(t, before.State, binding.State)
}
