package middleware

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/gin-gonic/gin"
	"shenliyuan/internal/models"
)

// 幂等结论必须是显式三态：handler 声明的「已提交」优先于状态码，
// 状态码只说明这次响应长什么样，说不出业务事务到底生效没有。
func TestClassifyIdempotentOutcome(t *testing.T) {
	cases := []struct {
		name                   string
		status                 int
		committed, safeToRetry bool
		want                   idempotencyOutcome
	}{
		{name: "成功", status: http.StatusOK, want: idempotencyOutcomeCompleted},
		{name: "业务拒绝可重试", status: http.StatusUnprocessableEntity, want: idempotencyOutcomeRetryable},
		{name: "限流可重试", status: http.StatusTooManyRequests, want: idempotencyOutcomeRetryable},
		{name: "结果未知的 5xx", status: http.StatusInternalServerError, want: idempotencyOutcomeUnknown},
		{name: "显式无副作用的 5xx", status: http.StatusServiceUnavailable, safeToRetry: true, want: idempotencyOutcomeRetryable},
		{name: "已提交但响应失败", status: http.StatusInternalServerError, committed: true, want: idempotencyOutcomeCompleted},
		{name: "已提交优先于可重试标记", status: http.StatusBadGateway, committed: true, safeToRetry: true, want: idempotencyOutcomeCompleted},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := classifyIdempotentOutcome(tc.status, tc.committed, tc.safeToRetry); got != tc.want {
				t.Fatalf("classify(%d, committed=%v, safe=%v) = %v, 期望 %v",
					tc.status, tc.committed, tc.safeToRetry, got, tc.want)
			}
		})
	}
}

// 业务已经落库、只是收尾失败时，同键重试必须重放这条失败结论，
// 而不是把用户卡在「请换一把键」，更不能重新执行一遍业务。
func TestIdempotencyMiddlewareReplaysCommittedNonSuccessResponse(t *testing.T) {
	db := openIdempotencyTestDB(t)
	var writes atomic.Int32
	router := newIdempotencyTestRouter(t, db, func(c *gin.Context) {
		writes.Add(1)
		MarkIdempotentCommitted(c)
		c.JSON(http.StatusInternalServerError, gin.H{"code": "notification_failed", "id": writes.Load()})
	})
	request := func() *httptest.ResponseRecorder {
		response := httptest.NewRecorder()
		router.ServeHTTP(response, requestWithKey(http.MethodPost, "/write", "committed-write", `{"title":"内容"}`))
		return response
	}
	first := request()
	retry := request()
	if first.Code != http.StatusInternalServerError || retry.Code != http.StatusInternalServerError {
		t.Fatalf("状态 = %d / %d", first.Code, retry.Code)
	}
	if first.Body.String() != retry.Body.String() {
		t.Fatalf("同键重试没有重放同一结论: %q vs %q", first.Body.String(), retry.Body.String())
	}
	if retry.Header().Get("Idempotency-Replay") != "true" {
		t.Fatalf("重放缺少标记: %q", retry.Header().Get("Idempotency-Replay"))
	}
	if writes.Load() != 1 {
		t.Fatalf("已提交的写入被重新执行: writes=%d", writes.Load())
	}
}

// 成功响应体超过缓存上限时只重放状态码。写入已经发生，宁可让调用方重新读一次，
// 也不能存半截正文、更不能放行同键重新执行。
func TestIdempotencyMiddlewareOversizedResponseBodyIsReplayedAsStatusOnly(t *testing.T) {
	db := openIdempotencyTestDB(t)
	var writes atomic.Int32
	big := strings.Repeat("a", idempotencyMaxResponseSize+1024)
	router := newIdempotencyTestRouter(t, db, func(c *gin.Context) {
		writes.Add(1)
		c.Data(http.StatusCreated, "application/json", []byte(`{"blob":"`+big+`"}`))
	})
	request := func() *httptest.ResponseRecorder {
		response := httptest.NewRecorder()
		router.ServeHTTP(response, requestWithKey(http.MethodPost, "/write", "big-response", `{"title":"内容"}`))
		return response
	}
	first := request()
	if first.Code != http.StatusCreated || first.Body.Len() != len(`{"blob":"`)+len(big)+len(`"}`) {
		t.Fatalf("首个响应应原样透传: status=%d len=%d", first.Code, first.Body.Len())
	}
	retry := request()
	if retry.Code != http.StatusCreated {
		t.Fatalf("重放状态 = %d", retry.Code)
	}
	if retry.Header().Get("Idempotency-Replay") != "body-omitted" {
		t.Fatalf("超限响应应标记 body-omitted: %q", retry.Header().Get("Idempotency-Replay"))
	}
	if retry.Body.Len() != 0 {
		t.Fatalf("超限响应不应重放正文: len=%d", retry.Body.Len())
	}
	if writes.Load() != 1 {
		t.Fatalf("写入被重新执行: writes=%d", writes.Load())
	}
}

// 缓存必须有界：超限响应只落状态码，完整正文不再进幂等记录。
func TestIdempotencyRecordDropsOversizedResponseBody(t *testing.T) {
	db := openIdempotencyTestDB(t)
	big := strings.Repeat("c", idempotencyMaxResponseSize+2048)
	router := newIdempotencyTestRouter(t, db, func(c *gin.Context) {
		c.Data(http.StatusOK, "application/json", []byte(`{"blob":"`+big+`"}`))
	})
	response := httptest.NewRecorder()
	router.ServeHTTP(response, requestWithKey(http.MethodPost, "/write", "cap-record", `{"title":"内容"}`))
	if response.Code != http.StatusOK {
		t.Fatalf("状态 = %d", response.Code)
	}
	var record models.IdempotencyRecord
	if err := db.Where("idempotency_key = ?", "cap-record").First(&record).Error; err != nil {
		t.Fatal(err)
	}
	if !record.ResponseBodyOmitted {
		t.Fatal("超限响应必须标记 ResponseBodyOmitted")
	}
	if len(record.ResponseBody) != 0 {
		t.Fatalf("超限正文不得入库: %d 字节", len(record.ResponseBody))
	}
}
