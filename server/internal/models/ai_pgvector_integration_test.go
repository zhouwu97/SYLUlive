package models

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestPGVectorMigrationIntegration 使用独立临时数据库 DSN 运行，默认不依赖开发机数据库。
func TestPGVectorMigrationIntegration(t *testing.T) {
	dsn := os.Getenv("PGVECTOR_TEST_DSN")
	if dsn == "" {
		t.Skip("未设置 PGVECTOR_TEST_DSN，跳过独立 pgvector 集成测试")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	connection, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatalf("连接 pgvector 测试库失败: %v", err)
	}
	defer connection.Close(context.Background())

	for _, migrationName := range []string{"20260719_ai_rag_pgvector.sql", "20260719_ai_runtime_rag.sql", "20260719_ai_privacy_quota.sql"} {
		migrationPath := filepath.Join("..", "..", "sql", migrationName)
		migration, err := os.ReadFile(migrationPath)
		if err != nil {
			t.Fatalf("读取 %s 失败: %v", migrationName, err)
		}
		if _, err := connection.Exec(ctx, string(migration)); err != nil {
			t.Fatalf("执行 %s 失败: %v", migrationName, err)
		}
	}
	var dimensions int
	if err := connection.QueryRow(ctx, "SELECT vector_dims(array_fill(0::real, ARRAY[1536])::vector)").Scan(&dimensions); err != nil {
		t.Fatalf("pgvector 维度验证失败: %v", err)
	}
	if dimensions != 1536 {
		t.Fatalf("embedding 维度=%d want=1536", dimensions)
	}
	var indexCount int
	if err := connection.QueryRow(ctx, `SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname IN ('idx_ai_knowledge_chunks_fts','idx_ai_knowledge_chunks_trgm','idx_ai_knowledge_chunks_embedding')`).Scan(&indexCount); err != nil {
		t.Fatalf("读取混合检索索引失败: %v", err)
	}
	if indexCount != 3 {
		t.Fatalf("混合检索索引数=%d want=3", indexCount)
	}
}
