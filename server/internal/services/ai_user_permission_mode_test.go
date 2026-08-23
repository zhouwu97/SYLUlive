package services

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestAIUserPermissionSetModeIsAtomicAndRoundTrips(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:ai_permission_mode?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.AIUserPermission{}))
	service := NewAIUserPermissionService(db)

	require.NoError(t, service.SetMode(context.Background(), 7, AIUserPermissionModeTrusted))
	mode, err := service.Mode(context.Background(), 7)
	require.NoError(t, err)
	require.Equal(t, AIUserPermissionModeTrusted, mode)
	externalPolicy, err := service.Policy(context.Background(), 7, models.AIUserPermissionExternalModelAnalysis)
	require.NoError(t, err)
	require.Equal(t, models.AIUserPermissionAsk, externalPolicy)

	require.NoError(t, service.SetMode(context.Background(), 7, AIUserPermissionModeAsk))
	mode, err = service.Mode(context.Background(), 7)
	require.NoError(t, err)
	require.Equal(t, AIUserPermissionModeAsk, mode)
}
