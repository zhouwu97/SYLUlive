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
		"ai_knowledge_documents", "ai_knowledge_chunks", "ai_knowledge_ingestion_jobs",
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
			('idx_ai_knowledge_chunks_embedding', 'idx_ai_knowledge_chunks_fts', 'idx_ai_knowledge_chunks_trgm')`).Scan(&indexCount).Error; err != nil {
			return fmt.Errorf("inspect AI indexes: %w", err)
		}
		if indexCount != 3 {
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
