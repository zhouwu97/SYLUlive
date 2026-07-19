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
