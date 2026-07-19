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

	migrationPath := filepath.Join("..", "..", "sql", "20260719_ai_rag_pgvector.sql")
	migration, err := os.ReadFile(migrationPath)
	if err != nil {
		t.Fatalf("读取 AI/RAG migration 失败: %v", err)
	}
	if _, err := connection.Exec(ctx, string(migration)); err != nil {
		t.Fatalf("执行 AI/RAG migration 失败: %v", err)
	}
	var dimensions int
	if err := connection.QueryRow(ctx, "SELECT vector_dims(array_fill(0::real, ARRAY[1536])::vector)").Scan(&dimensions); err != nil {
		t.Fatalf("pgvector 维度验证失败: %v", err)
	}
	if dimensions != 1536 {
		t.Fatalf("embedding 维度=%d want=1536", dimensions)
	}
}
