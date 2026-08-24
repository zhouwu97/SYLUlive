//go:build integration

package middleware

import (
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

func TestIdempotencyMiddlewarePostgresSmoke(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_DSN")
	if dsn == "" {
		t.Skip("未配置 TEST_DATABASE_DSN，跳过 PostgreSQL 幂等集成测试")
	}
	if os.Getenv("ALLOW_DESTRUCTIVE_INTEGRATION_TESTS") != "1" {
		t.Skip("未显式允许集成测试清理测试表")
	}

	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		t.Fatalf("open postgres: %v", err)
	}
	if err := models.EnsureIdempotencySchema(db); err != nil {
		t.Fatalf("migrate idempotency schema: %v", err)
	}
	if err := db.Exec("TRUNCATE TABLE idempotency_records RESTART IDENTITY").Error; err != nil {
		t.Fatalf("clean idempotency table: %v", err)
	}
	t.Cleanup(func() { _ = db.Exec("TRUNCATE TABLE idempotency_records") })

	gin.SetMode(gin.TestMode)
	var calls atomic.Int32
	router := gin.New()
	router.Use(IdempotencyMiddleware(db))
	router.POST("/write", func(c *gin.Context) {
		calls.Add(1)
		c.JSON(http.StatusCreated, gin.H{"created": true})
	})

	first := httptest.NewRecorder()
	router.ServeHTTP(first, requestWithKey(http.MethodPost, "/write", "pg-smoke", `{"value":1}`))
	retry := httptest.NewRecorder()
	router.ServeHTTP(retry, requestWithKey(http.MethodPost, "/write", "pg-smoke", `{"value":1}`))

	if first.Code != http.StatusCreated || retry.Code != http.StatusCreated {
		t.Fatalf("statuses=%d,%d, want 201,201", first.Code, retry.Code)
	}
	if calls.Load() != 1 {
		t.Fatalf("handler calls=%d, want 1", calls.Load())
	}
}
