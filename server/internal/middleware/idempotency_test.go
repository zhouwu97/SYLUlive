package middleware

import (
	"bytes"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

func TestIdempotencyMultipartCommentReplayAndPayloadConflict(t *testing.T) {
	db := openIdempotencyTestDB(t)
	var calls int
	router := newIdempotencyTestRouter(t, db, func(c *gin.Context) {
		calls++
		if c.PostForm("content") != "评论 boundary-a" || c.PostForm("file_ids") != "12" {
			t.Fatalf("表单未完整传递到业务层")
		}
		c.JSON(http.StatusCreated, gin.H{"id": calls})
	})
	request := func(boundary, content string) *httptest.ResponseRecorder {
		var body bytes.Buffer
		writer := multipart.NewWriter(&body)
		if err := writer.SetBoundary(boundary); err != nil {
			t.Fatal(err)
		}
		if err := writer.WriteField("content", content); err != nil {
			t.Fatal(err)
		}
		if err := writer.WriteField("file_ids", "12"); err != nil {
			t.Fatal(err)
		}
		if err := writer.Close(); err != nil {
			t.Fatal(err)
		}
		req := requestWithKey(http.MethodPost, "/write", "comment-retry", body.String())
		req.Header.Set("Content-Type", writer.FormDataContentType())
		response := httptest.NewRecorder()
		router.ServeHTTP(response, req)
		return response
	}
	first := request("boundary-a", "评论 boundary-a")
	retry := request("boundary-b", "评论 boundary-a")
	changed := request("boundary-b", "评论 boundary-b")
	if first.Code != 201 || retry.Code != 201 || first.Body.String() != retry.Body.String() || changed.Code != 409 || calls != 1 {
		t.Fatalf("statuses=%d/%d/%d calls=%d", first.Code, retry.Code, changed.Code, calls)
	}
}

func TestIdempotencyMultipartStillEnforcesBodyLimit(t *testing.T) {
	for _, unknownLength := range []bool{false, true} {
		db := openIdempotencyTestDB(t)
		router := newIdempotencyTestRouter(t, db, func(c *gin.Context) { t.Fatal("超大请求进入业务层") })
		req := requestWithKey(http.MethodPost, "/write", "large", strings.Repeat("x", idempotencyMaxBodySize+1))
		req.Header.Set("Content-Type", "multipart/form-data; boundary=test")
		if unknownLength {
			req.ContentLength = -1
		}
		response := httptest.NewRecorder()
		router.ServeHTTP(response, req)
		if response.Code != 413 {
			t.Fatalf("status=%d", response.Code)
		}
	}
}

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

func TestIdempotencyMiddlewareCanonicalizesJSONObjectKeyOrder(t *testing.T) {
	db := openIdempotencyTestDB(t)
	var calls atomic.Int32
	router := newIdempotencyTestRouter(t, db, func(c *gin.Context) {
		calls.Add(1)
		c.JSON(http.StatusCreated, gin.H{"id": 42})
	})

	first := httptest.NewRecorder()
	router.ServeHTTP(first, requestWithKey(http.MethodPost, "/write", "canonical-json", `{"b":2,"a":1}`))
	second := httptest.NewRecorder()
	router.ServeHTTP(second, requestWithKey(http.MethodPost, "/write", "canonical-json", "{\n  \"a\": 1, \"b\": 2\n}"))

	if first.Code != http.StatusCreated || second.Code != http.StatusCreated {
		t.Fatalf("statuses=%d,%d, want 201,201; second body=%s", first.Code, second.Code, second.Body.String())
	}
	if first.Body.String() != second.Body.String() || calls.Load() != 1 {
		t.Fatalf("canonical replay mismatch: first=%q second=%q calls=%d", first.Body.String(), second.Body.String(), calls.Load())
	}
}

func TestIdempotencyMiddlewareScopesSameKeyByUser(t *testing.T) {
	db := openIdempotencyTestDB(t)
	var calls atomic.Int32
	router := gin.New()
	router.Use(func(c *gin.Context) {
		c.Set("user_id", c.GetHeader("X-Test-User"))
		c.Next()
	})
	router.Use(IdempotencyMiddleware(db))
	router.POST("/write", func(c *gin.Context) {
		id := calls.Add(1)
		c.JSON(http.StatusCreated, gin.H{"call": id})
	})

	request := func(user string) *httptest.ResponseRecorder {
		recorder := httptest.NewRecorder()
		req := requestWithKey(http.MethodPost, "/write", "same-key-different-user", `{"value":1}`)
		req.Header.Set("X-Test-User", user)
		router.ServeHTTP(recorder, req)
		return recorder
	}

	first := request("user-a")
	second := request("user-b")
	if first.Code != http.StatusCreated || second.Code != http.StatusCreated {
		t.Fatalf("statuses=%d,%d, want 201,201", first.Code, second.Code)
	}
	if calls.Load() != 2 {
		t.Fatalf("same key crossed user scope: handler calls=%d, want 2", calls.Load())
	}
}

func TestIdempotencyMiddlewareWithJWTKeepsUserScopeAcrossTokenRotation(t *testing.T) {
	clearTokenVersionCacheForTest()
	db := openIdempotencyTestDB(t)
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}); err != nil {
		t.Fatalf("migrate auth state: %v", err)
	}
	user := models.User{StudentID: "idempotency-user", PasswordHash: "hash", Role: models.RoleUser}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	tokenOne, err := GenerateToken(user.ID, string(user.Role), user.TokenVersion, "idempotency-secret")
	if err != nil {
		t.Fatalf("generate first token: %v", err)
	}
	tokenTwo, err := GenerateToken(user.ID, string(user.Role), user.TokenVersion, "idempotency-secret")
	if err != nil {
		t.Fatalf("generate rotated token: %v", err)
	}

	var calls atomic.Int32
	router := gin.New()
	router.Use(IdempotencyMiddlewareWithJWT(db, "idempotency-secret"))
	router.POST("/write", func(c *gin.Context) {
		calls.Add(1)
		c.JSON(http.StatusCreated, gin.H{"created": true})
	})
	requestWithToken := func(token string) *httptest.ResponseRecorder {
		recorder := httptest.NewRecorder()
		request := requestWithKey(http.MethodPost, "/write", "jwt-same-key", `{"value":1}`)
		request.Header.Set("Authorization", "Bearer "+token)
		router.ServeHTTP(recorder, request)
		return recorder
	}

	first := requestWithToken(tokenOne)
	retry := requestWithToken(tokenTwo)
	if first.Code != http.StatusCreated || retry.Code != http.StatusCreated {
		t.Fatalf("statuses=%d,%d, want 201,201", first.Code, retry.Code)
	}
	if calls.Load() != 1 {
		t.Fatalf("token rotation changed user scope and duplicated action: calls=%d", calls.Load())
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

// TestIdempotencyMiddlewareReleasesFailedResponseForSameKeyRetry 锁住可安全重试的失败响应。
func TestIdempotencyMiddlewareReleasesFailedResponseForSameKeyRetry(t *testing.T) {
	for _, tc := range []struct {
		name       string
		failStatus int
	}{
		{name: "业务限流", failStatus: http.StatusTooManyRequests},
		{name: "明确无副作用的临时故障", failStatus: http.StatusServiceUnavailable},
		{name: "业务拒绝", failStatus: http.StatusForbidden},
	} {
		t.Run(tc.name, func(t *testing.T) {
			db := openIdempotencyTestDB(t)
			var calls atomic.Int32
			router := newIdempotencyTestRouter(t, db, func(c *gin.Context) {
				n := calls.Add(1)
				if n == 1 {
					if tc.failStatus >= 500 {
						MarkIdempotentSafeToRetry(c)
					}
					c.JSON(tc.failStatus, gin.H{"code": "try_again"})
					return
				}
				c.JSON(http.StatusCreated, gin.H{"id": n})
			})

			body := `{"title":"同一份请求"}`
			key := "retry-after-failure"
			first := httptest.NewRecorder()
			router.ServeHTTP(first, requestWithKey(http.MethodPost, "/write", key, body))
			if first.Code != tc.failStatus {
				t.Fatalf("首次状态 = %d, 期望 %d", first.Code, tc.failStatus)
			}

			// 故障恢复后必须能用同一把键原样重试，而不是被上一次的失败响应钉死。
			retry := httptest.NewRecorder()
			router.ServeHTTP(retry, requestWithKey(http.MethodPost, "/write", key, body))
			if retry.Code != http.StatusCreated {
				t.Fatalf("同键重试状态 = %d, 期望 201；body=%q", retry.Code, retry.Body.String())
			}
			if calls.Load() != 2 {
				t.Fatalf("失败记录未释放，业务层被跳过: calls=%d", calls.Load())
			}

			// 成功之后仍然只算一次：重放的是成功响应，不再进业务层。
			replay := httptest.NewRecorder()
			router.ServeHTTP(replay, requestWithKey(http.MethodPost, "/write", key, body))
			if replay.Code != http.StatusCreated || replay.Body.String() != retry.Body.String() {
				t.Fatalf("成功后未重放: %d %q vs %d %q",
					replay.Code, replay.Body.String(), retry.Code, retry.Body.String())
			}
			if calls.Load() != 2 {
				t.Fatalf("成功响应未被缓存: calls=%d", calls.Load())
			}
		})
	}
}

// TestIdempotencyMiddlewareFailedResponseDoesNotPoisonOtherPayload 再锁一层：
// 失败记录释放后，同一把键换成另一份请求体不会被判成 payload 冲突。
// 这正是"改了内容再提交"的用户路径——旧记录若还在，用户会卡在 idempotency_key_reused。
func TestIdempotencyMiddlewareFailedResponseDoesNotPoisonOtherPayload(t *testing.T) {
	db := openIdempotencyTestDB(t)
	var calls atomic.Int32
	router := newIdempotencyTestRouter(t, db, func(c *gin.Context) {
		n := calls.Add(1)
		if n == 1 {
			MarkIdempotentSafeToRetry(c)
			c.JSON(http.StatusServiceUnavailable, gin.H{"code": "unavailable"})
			return
		}
		c.JSON(http.StatusCreated, gin.H{"id": n})
	})
	key := "edit-then-resubmit"
	first := httptest.NewRecorder()
	router.ServeHTTP(first, requestWithKey(http.MethodPost, "/write", key, `{"title":"旧内容"}`))
	if first.Code != http.StatusServiceUnavailable {
		t.Fatalf("首次状态 = %d", first.Code)
	}
	second := httptest.NewRecorder()
	router.ServeHTTP(second, requestWithKey(http.MethodPost, "/write", key, `{"title":"新内容"}`))
	if second.Code != http.StatusCreated {
		t.Fatalf("修改内容后同键提交被拒: %d %q", second.Code, second.Body.String())
	}
	if calls.Load() != 2 {
		t.Fatalf("calls=%d", calls.Load())
	}
}

// 写入已发生但响应失败时，同键重试不得再次进入业务层。
func TestIdempotencyMiddlewareKeepsUncertainServerFailure(t *testing.T) {
	db := openIdempotencyTestDB(t)
	var writes atomic.Int32
	router := newIdempotencyTestRouter(t, db, func(c *gin.Context) {
		writes.Add(1)
		c.JSON(http.StatusInternalServerError, gin.H{"code": "notification_failed"})
	})
	request := func() *httptest.ResponseRecorder {
		response := httptest.NewRecorder()
		router.ServeHTTP(response, requestWithKey(http.MethodPost, "/write", "uncertain-write", `{"title":"内容"}`))
		return response
	}
	if first := request(); first.Code != http.StatusInternalServerError {
		t.Fatalf("首次状态 = %d", first.Code)
	}
	if retry := request(); retry.Code != http.StatusConflict || !strings.Contains(retry.Body.String(), "idempotency_request_failed") {
		t.Fatalf("未决写入被重新执行: %d %q", retry.Code, retry.Body.String())
	}
	if writes.Load() != 1 {
		t.Fatalf("业务写入次数 = %d", writes.Load())
	}
}
