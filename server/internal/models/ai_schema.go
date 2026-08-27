package models

import (
	"fmt"
	"strings"

	"gorm.io/gorm"
)

// ValidateAIRuntimeSchema 只读核验版本化 SQL 迁移结果，禁止 AutoMigrate 改写 pgvector 与运行时约束。
func ValidateAIRuntimeSchema(db *gorm.DB) error {
	if db == nil {
		return fmt.Errorf("database is nil")
	}
	tables := []string{
		"ai_knowledge_documents", "ai_knowledge_chunks", "ai_knowledge_chunk_embeddings", "ai_knowledge_ingestion_jobs",
		"ai_embedding_model_registry", "ai_conversations", "ai_conversation_messages",
		"ai_runs", "ai_events", "ai_tool_calls", "ai_run_resume_jobs", "ai_quota_entries",
		"ai_user_budgets", "ai_budget_reservations", "ai_usage_records", "class_period_profiles",
		// 授权链路的表缺失不能等到用户点“允许”时才暴露成数据库错误。
		"ai_user_permissions", "ai_run_consents",
	}
	missing := make([]string, 0)
	for _, table := range tables {
		if !db.Migrator().HasTable(table) {
			missing = append(missing, table)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing tables: %s", strings.Join(missing, ", "))
	}
	if db.Dialector.Name() == "postgres" {
		var extensionCount int64
		if err := db.Raw("SELECT count(*) FROM pg_extension WHERE extname IN ('vector', 'pg_trgm')").Scan(&extensionCount).Error; err != nil {
			return fmt.Errorf("inspect AI extensions: %w", err)
		}
		if extensionCount != 2 {
			return fmt.Errorf("vector or pg_trgm extension is missing")
		}
		var indexCount int64
		if err := db.Raw(`SELECT count(*) FROM pg_indexes WHERE schemaname = current_schema() AND indexname IN
			('idx_ai_knowledge_chunks_embedding', 'idx_ai_knowledge_chunks_fts', 'idx_ai_knowledge_chunks_trgm',
			 'idx_ai_chunk_embeddings_model_dimensions', 'idx_ai_chunk_embeddings_hnsw_384',
			 'idx_ai_chunk_embeddings_hnsw_1536')`).Scan(&indexCount).Error; err != nil {
			return fmt.Errorf("inspect AI indexes: %w", err)
		}
		if indexCount != 6 {
			return fmt.Errorf("hybrid retrieval indexes are incomplete")
		}
		var quotaRunForeignKeys int64
		if err := db.Raw(`SELECT count(*)
			FROM pg_constraint constraint_row
			JOIN pg_class table_row ON table_row.oid = constraint_row.conrelid
			WHERE table_row.relname = 'ai_quota_entries' AND constraint_row.contype = 'f'`).Scan(&quotaRunForeignKeys).Error; err != nil {
			return fmt.Errorf("inspect AI quota constraints: %w", err)
		}
		if quotaRunForeignKeys != 0 {
			return fmt.Errorf("AI quota ledger must not cascade with Run deletion")
		}
	}
	return nil
}

// ValidateAIUserPermissionSchema 只读核验 Agent 长期权限表的生产约束。
// 该约束由版本化 SQL 维护，不能依赖 GORM AutoMigrate 自动修改命名约束。
func ValidateAIUserPermissionSchema(db *gorm.DB) error {
	if db == nil {
		return fmt.Errorf("database is nil")
	}
	if !db.Migrator().HasTable("ai_user_permissions") {
		return fmt.Errorf("missing table: ai_user_permissions")
	}
	if db.Dialector.Name() != "postgres" {
		return nil
	}

	type columnInfo struct {
		ColumnName string `gorm:"column:column_name"`
		IsNullable string `gorm:"column:is_nullable"`
	}
	var columns []columnInfo
	if err := db.Raw(`
		SELECT column_name, is_nullable
		FROM information_schema.columns
		WHERE table_schema = current_schema()
		  AND table_name = 'ai_user_permissions'
		  AND column_name IN ('user_id', 'scope', 'policy', 'version')
	`).Scan(&columns).Error; err != nil {
		return fmt.Errorf("AI_PERMISSION_SCHEMA_DATABASE_UNAVAILABLE: inspect permission columns: %w", err)
	}
	columnByName := make(map[string]columnInfo, len(columns))
	for _, column := range columns {
		columnByName[column.ColumnName] = column
	}
	for _, name := range []string{"user_id", "scope", "policy", "version"} {
		column, ok := columnByName[name]
		if !ok {
			return fmt.Errorf("AI_PERMISSION_SCHEMA_INVALID: missing column ai_user_permissions.%s", name)
		}
		if strings.ToUpper(column.IsNullable) != "NO" {
			return fmt.Errorf("AI_PERMISSION_SCHEMA_INVALID: column ai_user_permissions.%s must be NOT NULL", name)
		}
	}

	var uniqueIndexCount int64
	if err := db.Raw(`
		SELECT count(*)
		FROM pg_index AS index_row
		JOIN pg_class AS index_class ON index_class.oid = index_row.indexrelid
		JOIN pg_class AS table_row ON table_row.oid = index_row.indrelid
		JOIN pg_namespace AS namespace_row ON namespace_row.oid = table_row.relnamespace
		WHERE namespace_row.nspname = current_schema()
		  AND table_row.relname = 'ai_user_permissions'
		  AND index_row.indisunique
		  AND regexp_replace(pg_get_indexdef(index_row.indexrelid), '\s+', '', 'g')
		      LIKE '%(user_id,scope)%'
	`).Scan(&uniqueIndexCount).Error; err != nil {
		return fmt.Errorf("AI_PERMISSION_SCHEMA_DATABASE_UNAVAILABLE: inspect permission unique index: %w", err)
	}
	if uniqueIndexCount == 0 {
		return fmt.Errorf("AI_PERMISSION_SCHEMA_INVALID: missing unique index on ai_user_permissions(user_id, scope)")
	}

	type constraintInfo struct {
		Name       string `gorm:"column:conname"`
		Definition string `gorm:"column:definition"`
	}
	var constraints []constraintInfo
	if err := db.Raw(`
		SELECT conname, pg_get_constraintdef(oid) AS definition
		FROM pg_constraint
		WHERE conrelid = 'ai_user_permissions'::regclass
		  AND contype = 'c'
		  AND conname IN ('chk_ai_user_permissions_scope', 'chk_ai_user_permissions_policy')
	`).Scan(&constraints).Error; err != nil {
		return fmt.Errorf("AI_PERMISSION_SCHEMA_DATABASE_UNAVAILABLE: inspect permission checks: %w", err)
	}
	constraintByName := make(map[string]string, len(constraints))
	for _, constraint := range constraints {
		constraintByName[constraint.Name] = constraint.Definition
	}
	if err := validateAIUserPermissionScopeConstraint(constraintByName["chk_ai_user_permissions_scope"]); err != nil {
		return fmt.Errorf("AI_PERMISSION_SCHEMA_INVALID: %w", err)
	}
	if err := validateAIUserPermissionPolicyConstraint(constraintByName["chk_ai_user_permissions_policy"]); err != nil {
		return fmt.Errorf("AI_PERMISSION_SCHEMA_INVALID: %w", err)
	}
	return nil
}

func validateAIUserPermissionScopeConstraint(definition string) error {
	definition = strings.ToLower(definition)
	for _, scope := range []string{
		"ai_personal_data_access",
		"ai_device_cache_access",
		"ai_remote_edu_refresh",
		"erke_snapshot_upload",
		"academic_cloud_storage",
		"ai_external_model_analysis",
	} {
		if !strings.Contains(definition, "'"+scope+"'") {
			return fmt.Errorf("scope CHECK constraint is missing %s", scope)
		}
	}
	return nil
}

func validateAIUserPermissionPolicyConstraint(definition string) error {
	definition = strings.ToLower(definition)
	for _, policy := range []string{"ask", "always", "never"} {
		if !strings.Contains(definition, "'"+policy+"'") {
			return fmt.Errorf("policy CHECK constraint is missing %s", policy)
		}
	}
	return nil
}
