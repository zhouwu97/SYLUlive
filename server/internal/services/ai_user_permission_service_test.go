package services

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestAIUserPermissionServiceDefaultsAndPersistsOnlyKnownPolicies(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:ai_user_permissions?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.AIUserPermission{}))
	service := NewAIUserPermissionService(db)
	ctx := context.Background()

	permissions, err := service.List(ctx, 7)
	require.NoError(t, err)
	require.Len(t, permissions, 6)
	for _, permission := range permissions {
		require.Equal(t, models.AIUserPermissionAsk, permission.Policy)
	}
	require.Equal(t, models.AIUserPermissionExternalModelAnalysis, permissions[5].Scope)

	stored, err := service.Set(ctx, 7, models.AIUserPermissionDeviceCacheAccess, models.AIUserPermissionNever)
	require.NoError(t, err)
	require.Equal(t, models.AIUserPermissionNever, stored.Policy)
	policy, err := service.Policy(ctx, 7, models.AIUserPermissionDeviceCacheAccess)
	require.NoError(t, err)
	require.Equal(t, models.AIUserPermissionNever, policy)

	_, err = service.Set(ctx, 7, "unknown_scope", models.AIUserPermissionAlways)
	require.ErrorIs(t, err, ErrInvalidAIUserPermission)
	_, err = service.Set(ctx, 7, models.AIUserPermissionDeviceCacheAccess, "session")
	require.ErrorIs(t, err, ErrInvalidAIUserPermission)
}

func TestAIUserPermissionServiceSetModeUpdatesAllAgentScopes(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:ai_user_permissions_set_mode?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.AIUserPermission{}))
	service := NewAIUserPermissionService(db)
	ctx := context.Background()

	require.NoError(t, service.SetMode(ctx, 7, AIUserPermissionModeTrusted))
	mode, err := service.Mode(ctx, 7)
	require.NoError(t, err)
	require.Equal(t, AIUserPermissionModeTrusted, mode)

	require.NoError(t, service.SetMode(ctx, 7, AIUserPermissionModeAsk))
	mode, err = service.Mode(ctx, 7)
	require.NoError(t, err)
	require.Equal(t, AIUserPermissionModeAsk, mode)

	externalPolicy, err := service.Policy(ctx, 7, models.AIUserPermissionExternalModelAnalysis)
	require.NoError(t, err)
	require.Equal(t, models.AIUserPermissionAsk, externalPolicy)
}
