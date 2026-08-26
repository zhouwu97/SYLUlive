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

// ValidateAIUserPermissionSchema 只读核验 Agent 长期权限的关键 CHECK 约束。
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

	var definition string
	if err := db.Raw(`
		SELECT pg_get_constraintdef(oid)
		FROM pg_constraint
		WHERE conrelid = 'ai_user_permissions'::regclass
		  AND conname = 'chk_ai_user_permissions_scope'
	`).Scan(&definition).Error; err != nil {
		return fmt.Errorf("inspect AI user permission scope constraint: %w", err)
	}
	if err := validateAIUserPermissionScopeConstraint(definition); err != nil {
		return err
	}
	return nil
}

func validateAIUserPermissionScopeConstraint(definition string) error {
	if !strings.Contains(strings.ToLower(definition), "ai_external_model_analysis") {
		return fmt.Errorf("AI user permission scope constraint is outdated; execute server/sql/20260726_ai_external_model_permission.sql")
	}
	return nil
}
