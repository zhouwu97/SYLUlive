//go:build integration

package middleware

import (
	"database/sql"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	_ "github.com/jackc/pgx/v5/stdlib"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

func TestIdempotencyMiddlewarePostgresSmoke(t *testing.T) {
	db, cleanup := openIdempotencyPostgresTestDB(t)
	defer cleanup()

	var calls atomic.Int32
	router := newPostgresIdempotencyRouter(db, func(c *gin.Context) {
		calls.Add(1)
		c.JSON(http.StatusCreated, gin.H{"created": true, "id": 7})
	})

	first := httptestResponse(t, router, http.MethodPost, "/write", "pg-smoke", "user-1", `{"value":1}`)
	retry := httptestResponse(t, router, http.MethodPost, "/write", "pg-smoke", "user-1", `{"value":1}`)
	if first.Code != http.StatusCreated || retry.Code != http.StatusCreated {
		t.Fatalf("statuses=%d,%d, want 201,201", first.Code, retry.Code)
	}
	if first.Body.String() != retry.Body.String() || calls.Load() != 1 {
		t.Fatalf("replay mismatch: first=%q retry=%q calls=%d", first.Body.String(), retry.Body.String(), calls.Load())
	}
}

func TestIdempotencyMiddlewarePostgresRejectsPayloadConflict(t *testing.T) {
	db, cleanup := openIdempotencyPostgresTestDB(t)
	defer cleanup()

	var calls atomic.Int32
	router := newPostgresIdempotencyRouter(db, func(c *gin.Context) {
		calls.Add(1)
		c.JSON(http.StatusCreated, gin.H{"created": true})
	})

	first := httptestResponse(t, router, http.MethodPost, "/write", "pg-conflict", "user-1", `{"value":1}`)
	changed := httptestResponse(t, router, http.MethodPost, "/write", "pg-conflict", "user-1", `{"value":2}`)
	if first.Code != http.StatusCreated || changed.Code != http.StatusConflict {
		t.Fatalf("statuses=%d,%d, want 201,409; conflict body=%s", first.Code, changed.Code, changed.Body.String())
	}
	if calls.Load() != 1 {
		t.Fatalf("payload conflict executed handler %d times, want 1", calls.Load())
	}
}

func TestIdempotencyMiddlewarePostgresSameKeyIsolatedByUser(t *testing.T) {
	db, cleanup := openIdempotencyPostgresTestDB(t)
	defer cleanup()

	var calls atomic.Int32
	router := newPostgresIdempotencyRouter(db, func(c *gin.Context) {
		calls.Add(1)
		c.JSON(http.StatusCreated, gin.H{"created": true})
	})

	first := httptestResponse(t, router, http.MethodPost, "/write", "pg-same-key", "user-a", `{"value":1}`)
	second := httptestResponse(t, router, http.MethodPost, "/write", "pg-same-key", "user-b", `{"value":1}`)
	if first.Code != http.StatusCreated || second.Code != http.StatusCreated {
		t.Fatalf("statuses=%d,%d, want 201,201", first.Code, second.Code)
	}
	if calls.Load() != 2 {
		t.Fatalf("same key crossed user scopes: handler calls=%d, want 2", calls.Load())
	}
}

func TestIdempotencyMiddlewarePostgresConcurrentSameKeyRunsOnce(t *testing.T) {
	db, cleanup := openIdempotencyPostgresTestDB(t)
	defer cleanup()

	var calls atomic.Int32
	started := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	router := newPostgresIdempotencyRouter(db, func(c *gin.Context) {
		calls.Add(1)
		once.Do(func() { close(started) })
		<-release
		c.JSON(http.StatusCreated, gin.H{"created": true})
	})

	const requests = 10
	responses := make([]*httptest.ResponseRecorder, requests)
	var group sync.WaitGroup
	for index := 0; index < requests; index++ {
		group.Add(1)
		go func(index int) {
			defer group.Done()
			responses[index] = httptestResponse(t, router, http.MethodPost, "/write", "pg-concurrent", "user-1", `{"value":1}`)
		}(index)
	}
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("first PostgreSQL request did not reach handler")
	}
	close(release)
	group.Wait()

	for index, response := range responses {
		if response.Code != http.StatusCreated {
			t.Fatalf("request %d status=%d body=%s, want 201", index, response.Code, response.Body.String())
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("concurrent same key executed handler %d times, want 1", calls.Load())
	}
}

func TestIdempotencyMiddlewarePostgresLostResponseCanReplayWithoutDuplicate(t *testing.T) {
	db, cleanup := openIdempotencyPostgresTestDB(t)
	defer cleanup()

	var calls atomic.Int32
	router := newPostgresIdempotencyRouter(db, func(c *gin.Context) {
		id := calls.Add(1)
		c.JSON(http.StatusCreated, gin.H{"business_id": id})
	})

	// 模拟客户端已收到服务端处理结果但人为丢弃响应体；重试只能重放同一结果。
	_ = httptestResponse(t, router, http.MethodPost, "/write", "pg-lost-response", "user-1", `{"value":1}`)
	retry := httptestResponse(t, router, http.MethodPost, "/write", "pg-lost-response", "user-1", `{"value":1}`)
	if retry.Code != http.StatusCreated || retry.Body.String() != `{"business_id":1}` {
		t.Fatalf("retry status/body=%d/%s, want 201/{business_id:1}", retry.Code, retry.Body.String())
	}
	if calls.Load() != 1 {
		t.Fatalf("lost response retry duplicated business action: calls=%d", calls.Load())
	}
}

func openIdempotencyPostgresTestDB(t *testing.T) (*gorm.DB, func()) {
	t.Helper()
	dsn := strings.TrimSpace(os.Getenv("TEST_DATABASE_DSN"))
	if dsn == "" {
		t.Skip("未配置 TEST_DATABASE_DSN，跳过 PostgreSQL 幂等集成测试")
	}

	adminDB, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatalf("open postgres admin connection: %v", err)
	}
	adminDB.SetMaxOpenConns(1)
	adminDB.SetMaxIdleConns(1)
	if err := adminDB.Ping(); err != nil {
		_ = adminDB.Close()
		t.Fatalf("ping postgres: %v", err)
	}

	schema := fmt.Sprintf("idempotency_ci_%d", os.Getpid())
	if _, err := adminDB.Exec("CREATE SCHEMA " + schema); err != nil {
		_ = adminDB.Close()
		t.Fatalf("create isolated schema: %v", err)
	}

	db, err := gorm.Open(postgres.Open(withIdempotencySearchPath(dsn, schema)), &gorm.Config{})
	if err != nil {
		_, _ = adminDB.Exec("DROP SCHEMA IF EXISTS " + schema + " CASCADE")
		_ = adminDB.Close()
		t.Fatalf("open isolated postgres schema: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get postgres connection pool: %v", err)
	}
	sqlDB.SetMaxOpenConns(30)
	sqlDB.SetMaxIdleConns(30)
	if err := models.EnsureIdempotencySchema(db); err != nil {
		t.Fatalf("migrate idempotency schema: %v", err)
	}

	cleanup := func() {
		_ = sqlDB.Close()
		_, _ = adminDB.Exec("DROP SCHEMA IF EXISTS " + schema + " CASCADE")
		_ = adminDB.Close()
	}
	return db, cleanup
}

func withIdempotencySearchPath(dsn, schema string) string {
	parsed, err := url.Parse(dsn)
	if err != nil {
		return dsn + " options='-c search_path=" + schema + ",public'"
	}
	query := parsed.Query()
	query.Set("options", "-c search_path="+schema+",public")
	parsed.RawQuery = query.Encode()
	return parsed.String()
}

func newPostgresIdempotencyRouter(db *gorm.DB, handler gin.HandlerFunc) *gin.Engine {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(func(c *gin.Context) {
		if user := c.GetHeader("X-Test-User"); user != "" {
			c.Set("user_id", user)
		}
		c.Next()
	})
	router.Use(IdempotencyMiddleware(db))
	router.POST("/write", handler)
	return router
}

func httptestResponse(t *testing.T, router *gin.Engine, method, path, key, user, body string) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	request := requestWithKey(method, path, key, body)
	request.Header.Set("X-Test-User", user)
	router.ServeHTTP(recorder, request)
	return recorder
}
