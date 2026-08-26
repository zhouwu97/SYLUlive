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
	db := newAIUserPermissionModeTestDB(t)
	require.NoError(t, db.AutoMigrate(&models.AIUserPermission{}))
	service := NewAIUserPermissionService(db)

	_, err := service.Set(
		context.Background(), 7,
		models.AIUserPermissionExternalModelAnalysis,
		models.AIUserPermissionAlways,
	)
	require.NoError(t, err)
	require.NoError(t, service.SetMode(context.Background(), 7, AIUserPermissionModeTrusted))
	mode, err := service.Mode(context.Background(), 7)
	require.NoError(t, err)
	require.Equal(t, AIUserPermissionModeTrusted, mode)
	externalPolicy, err := service.Policy(context.Background(), 7, models.AIUserPermissionExternalModelAnalysis)
	require.NoError(t, err)
	require.Equal(t, models.AIUserPermissionAlways, externalPolicy)

	require.NoError(t, service.SetMode(context.Background(), 7, AIUserPermissionModeAsk))
	mode, err = service.Mode(context.Background(), 7)
	require.NoError(t, err)
	require.Equal(t, AIUserPermissionModeAsk, mode)
	externalPolicy, err = service.Policy(context.Background(), 7, models.AIUserPermissionExternalModelAnalysis)
	require.NoError(t, err)
	require.Equal(t, models.AIUserPermissionAlways, externalPolicy)

	_, err = service.Set(
		context.Background(), 7,
		models.AIUserPermissionExternalModelAnalysis,
		models.AIUserPermissionNever,
	)
	require.NoError(t, err)
	require.NoError(t, service.SetMode(context.Background(), 7, AIUserPermissionModeTrusted))
	externalPolicy, err = service.Policy(context.Background(), 7, models.AIUserPermissionExternalModelAnalysis)
	require.NoError(t, err)
	require.Equal(t, models.AIUserPermissionNever, externalPolicy)
}

func TestAIUserPermissionSetModeWorksWithLegacyScopeConstraint(t *testing.T) {
	db := newAIUserPermissionModeTestDB(t)
	require.NoError(t, db.Exec(`
CREATE TABLE ai_user_permissions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    scope VARCHAR(48) NOT NULL,
    policy VARCHAR(16) NOT NULL DEFAULT 'ask',
    version INTEGER NOT NULL DEFAULT 1,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    UNIQUE (user_id, scope),
    CHECK (scope IN (
        'ai_personal_data_access',
        'ai_device_cache_access',
        'ai_remote_edu_refresh',
        'erke_snapshot_upload',
        'academic_cloud_storage'
    )),
    CHECK (policy IN ('ask', 'always', 'never'))
)`).Error)
	service := NewAIUserPermissionService(db)

	require.NoError(t, service.SetMode(context.Background(), 7, AIUserPermissionModeTrusted))
	var rows []models.AIUserPermission
	require.NoError(t, db.Where("user_id = ?", 7).Find(&rows).Error)
	require.Len(t, rows, 5)
	for _, row := range rows {
		require.NotEqual(t, models.AIUserPermissionExternalModelAnalysis, row.Scope)
		require.Equal(t, models.AIUserPermissionAlways, row.Policy)
	}
}

func TestAIUserPermissionSetModeRollsBackWhenOneWriteFails(t *testing.T) {
	db := newAIUserPermissionModeTestDB(t)
	require.NoError(t, db.Exec(`
CREATE TABLE ai_user_permissions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    scope VARCHAR(48) NOT NULL,
    policy VARCHAR(16) NOT NULL DEFAULT 'ask',
    version INTEGER NOT NULL DEFAULT 1,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    UNIQUE (user_id, scope),
    CHECK (scope IN (
        'ai_personal_data_access',
        'ai_device_cache_access',
        'ai_remote_edu_refresh',
        'erke_snapshot_upload',
        'academic_cloud_storage',
        'ai_external_model_analysis'
    )),
    CHECK (policy IN ('ask', 'always', 'never')),
    CHECK (scope <> 'ai_remote_edu_refresh' OR policy <> 'always')
)`).Error)
	service := NewAIUserPermissionService(db)
	for _, scope := range []models.AIUserPermissionScope{
		models.AIUserPermissionPersonalDataAccess,
		models.AIUserPermissionDeviceCacheAccess,
		models.AIUserPermissionRemoteEduRefresh,
	} {
		_, err := service.Set(context.Background(), 7, scope, models.AIUserPermissionAsk)
		require.NoError(t, err)
	}

	require.Error(t, service.SetMode(context.Background(), 7, AIUserPermissionModeTrusted))
	var rows []models.AIUserPermission
	require.NoError(t, db.Where("user_id = ?", 7).Order("scope").Find(&rows).Error)
	require.Len(t, rows, 3)
	for _, row := range rows {
		require.Equal(t, models.AIUserPermissionAsk, row.Policy)
		require.Equal(t, int64(1), row.Version)
	}
}

func newAIUserPermissionModeTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:ai_permission_mode_"+t.Name()+"?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	t.Cleanup(func() { _ = sqlDB.Close() })
	return db
}
