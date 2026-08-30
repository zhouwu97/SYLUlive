package models

import (
	"testing"

	"github.com/stretchr/testify/require"
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
