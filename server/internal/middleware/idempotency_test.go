package middleware

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

func newIdempotencyTestRouter(t *testing.T, db *gorm.DB, handler gin.HandlerFunc) *gin.Engine {
	t.Helper()
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(IdempotencyMiddleware(db))
	router.POST("/write", handler)
	router.GET("/read", handler)
	return router
}

func openIdempotencyTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "idempotency.db")), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get sqlite db: %v", err)
	}
	sqlDB.SetMaxOpenConns(8)
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := models.EnsureIdempotencySchema(db); err != nil {
		t.Fatalf("migrate idempotency schema: %v", err)
	}
	return db
}

func requestWithKey(method, path, key, body string) *http.Request {
	req := httptest.NewRequest(method, path, bytes.NewBufferString(body))
	req.Header.Set("Authorization", "Bearer test-token")
	if key != "" {
		req.Header.Set("Idempotency-Key", key)
	}
	req.Header.Set("Content-Type", "application/json")
	return req
}

func TestIdempotencyMiddlewareReplaysCompletedResponse(t *testing.T) {
	db := openIdempotencyTestDB(t)
	var calls atomic.Int32
	router := newIdempotencyTestRouter(t, db, func(c *gin.Context) {
		calls.Add(1)
		c.JSON(http.StatusCreated, gin.H{"id": 7, "status": "created"})
	})

	first := httptest.NewRecorder()
	router.ServeHTTP(first, requestWithKey(http.MethodPost, "/write", "create-1", `{"title":"x"}`))
	second := httptest.NewRecorder()
	router.ServeHTTP(second, requestWithKey(http.MethodPost, "/write", "create-1", `{"title":"x"}`))

	if first.Code != http.StatusCreated || second.Code != http.StatusCreated {
		t.Fatalf("statuses=%d,%d, want 201,201", first.Code, second.Code)
	}
	if first.Body.String() != second.Body.String() {
		t.Fatalf("replayed body=%q, first=%q", second.Body.String(), first.Body.String())
	}
	if calls.Load() != 1 {
		t.Fatalf("handler calls=%d, want 1", calls.Load())
	}
}

func TestIdempotencyMiddlewareConcurrentSameKeyRunsOnce(t *testing.T) {
	db := openIdempotencyTestDB(t)
	started := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	var calls atomic.Int32
	router := newIdempotencyTestRouter(t, db, func(c *gin.Context) {
		calls.Add(1)
		once.Do(func() { close(started) })
		<-release
		c.JSON(http.StatusOK, gin.H{"ok": true})
	})

	first := httptest.NewRecorder()
	firstDone := make(chan struct{})
	go func() {
		router.ServeHTTP(first, requestWithKey(http.MethodPost, "/write", "same-1", `{"value":1}`))
		close(firstDone)
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("first request did not reach handler")
	}

	second := httptest.NewRecorder()
	secondDone := make(chan struct{})
	go func() {
		router.ServeHTTP(second, requestWithKey(http.MethodPost, "/write", "same-1", `{"value":1}`))
		close(secondDone)
	}()

	time.Sleep(50 * time.Millisecond)
	close(release)
	<-firstDone
	<-secondDone

	if first.Code != http.StatusOK || second.Code != http.StatusOK {
		t.Fatalf("statuses=%d,%d, want 200,200", first.Code, second.Code)
	}
	if first.Body.String() != second.Body.String() || calls.Load() != 1 {
		t.Fatalf("concurrent replay body/calls mismatch: first=%q second=%q calls=%d", first.Body.String(), second.Body.String(), calls.Load())
	}
}

func TestIdempotencyMiddlewareRejectsChangedPayloadAndKeepsDifferentKeysIndependent(t *testing.T) {
	db := openIdempotencyTestDB(t)
	var calls atomic.Int32
	router := newIdempotencyTestRouter(t, db, func(c *gin.Context) {
		calls.Add(1)
		c.JSON(http.StatusOK, gin.H{"calls": calls.Load()})
	})

	first := httptest.NewRecorder()
	router.ServeHTTP(first, requestWithKey(http.MethodPost, "/write", "key-a", `{"value":1}`))
	changed := httptest.NewRecorder()
	router.ServeHTTP(changed, requestWithKey(http.MethodPost, "/write", "key-a", `{"value":2}`))
	different := httptest.NewRecorder()
	router.ServeHTTP(different, requestWithKey(http.MethodPost, "/write", "key-b", `{"value":2}`))

	if changed.Code != http.StatusConflict {
		t.Fatalf("changed payload status=%d, want 409 body=%s", changed.Code, changed.Body.String())
	}
	if different.Code != http.StatusOK || calls.Load() != 2 {
		t.Fatalf("different key status/calls=%d/%d, want 200/2", different.Code, calls.Load())
	}
}

func TestIdempotencyMiddlewareDoesNotRecordReads(t *testing.T) {
	db := openIdempotencyTestDB(t)
	router := newIdempotencyTestRouter(t, db, func(c *gin.Context) { c.Status(http.StatusNoContent) })
	response := httptest.NewRecorder()
	router.ServeHTTP(response, requestWithKey(http.MethodGet, "/read", "read-key", ""))

	if response.Code != http.StatusNoContent {
		t.Fatalf("read status=%d, want 204", response.Code)
	}
	var count int64
	if err := db.Model(&models.IdempotencyRecord{}).Count(&count).Error; err != nil {
		t.Fatalf("count records: %v", err)
	}
	if count != 0 {
		t.Fatalf("read created %d idempotency records", count)
	}
	if _, err := io.Copy(io.Discard, response.Body); err != nil {
		t.Fatalf("read response: %v", err)
	}
}
