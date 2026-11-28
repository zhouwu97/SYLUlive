package models

import (
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"gorm.io/driver/postgres"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func TestValidateAIRuntimeSchemaReportsMissingMigration(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	err = ValidateAIRuntimeSchema(db)
	require.Error(t, err)
	require.Contains(t, err.Error(), "ai_knowledge_documents")
}

func TestValidateAIUserPermissionScopeConstraintRequiresExternalModelScope(t *testing.T) {
	require.Error(t, validateAIUserPermissionScopeConstraint(`CHECK (scope IN ('ai_personal_data_access', 'academic_cloud_storage'))`))
	require.NoError(t, validateAIUserPermissionScopeConstraint(`CHECK (scope IN (
		'ai_personal_data_access', 'ai_device_cache_access', 'ai_remote_edu_refresh',
		'erke_snapshot_upload', 'academic_cloud_storage', 'ai_external_model_analysis'
	))`))
}

func TestValidateAIUserPermissionPolicyConstraintRequiresKnownPolicies(t *testing.T) {
	require.Error(t, validateAIUserPermissionPolicyConstraint(`CHECK (policy IN ('ask', 'always'))`))
	require.NoError(t, validateAIUserPermissionPolicyConstraint(`CHECK (policy IN ('ask', 'always', 'never'))`))
}

func TestValidateAIUserPermissionSchemaRequiresTable(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.ErrorContains(t, ValidateAIUserPermissionSchema(db), "ai_user_permissions")
}

// 空库首次启动：AutoMigrate 新建的表补齐 CHECK 后应通过启动校验，并拒绝未知 scope。
func TestCreateAIUserPermissionChecksOnFreshTablePostgres(t *testing.T) {
	dsn := os.Getenv("TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("TEST_POSTGRES_DSN 未配置，跳过真实 PostgreSQL 集成测试")
	}
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	defer sqlDB.Close()
	schema := fmt.Sprintf("ai_permission_test_%d", time.Now().UnixNano())
	require.NoError(t, db.Exec("CREATE SCHEMA "+schema).Error)
	defer func() {
		_ = db.Exec("SET search_path TO public").Error
		_ = db.Exec("DROP SCHEMA IF EXISTS " + schema + " CASCADE").Error
	}()
	require.NoError(t, db.Exec("SET search_path TO "+schema).Error)

	require.NoError(t, db.AutoMigrate(&User{}, &AIUserPermission{}))
	require.ErrorContains(t, ValidateAIUserPermissionSchema(db), "AI_PERMISSION_SCHEMA_INVALID")

	require.NoError(t, CreateAIUserPermissionChecks(db))
	require.NoError(t, ValidateAIUserPermissionSchema(db))

	user := User{StudentID: "ai-permission-check", Nickname: "check", PasswordHash: "x"}
	require.NoError(t, db.Create(&user).Error)
	require.Error(t, db.Create(&AIUserPermission{UserID: user.ID, Scope: "unknown_scope", Policy: "ask"}).Error)
}
