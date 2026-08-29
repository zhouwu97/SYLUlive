package middleware

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestRequestTraceMiddlewareKeepsRequestIDAndNormalizesAPIError(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(RequestTraceMiddleware())
	router.GET("/api/example", func(c *gin.Context) {
		if got := RequestIDFromContext(c.Request.Context()); got != "client-trace-1" {
			t.Fatalf("context request id=%q", got)
		}
		c.JSON(http.StatusConflict, gin.H{
			"code":             "example_conflict",
			"error":            "业务状态冲突",
			"remote_reference": "opaque-reference",
		})
	})

	request := httptest.NewRequest(http.MethodGet, "/api/example", nil)
	request.Header.Set("X-Request-ID", "client-trace-1")
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)

	if response.Code != http.StatusConflict {
		t.Fatalf("status=%d, want %d", response.Code, http.StatusConflict)
	}
	if got := response.Header().Get("X-Request-ID"); got != "client-trace-1" {
		t.Fatalf("response request id=%q", got)
	}
	var body map[string]interface{}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body["code"] != "example_conflict" || body["message"] != "业务状态冲突" ||
		body["request_id"] != "client-trace-1" {
		t.Fatalf("unexpected normalized response: %#v", body)
	}
	if _, exists := body["error"]; exists {
		t.Fatalf("legacy error field must not be exposed: %#v", body)
	}
	details, ok := body["details"].(map[string]interface{})
	if !ok || details["remote_reference"] != "opaque-reference" {
		t.Fatalf("details not preserved: %#v", body)
	}
}

func TestRequestTraceMiddlewareGeneratesRequestID(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(RequestTraceMiddleware())
	router.GET("/api/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"ok": true})
	})

	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/health", nil))

	requestID := response.Header().Get("X-Request-ID")
	if requestID == "" {
		t.Fatal("expected generated X-Request-ID")
	}
	if len(requestID) != 36 {
		t.Fatalf("generated request id=%q is not UUID-shaped", requestID)
	}
}

func TestRequestTraceMiddlewareDoesNotMaskRouterLevel404(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(RequestTraceMiddleware())
	router.GET("/api/known", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"ok": true})
	})

	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodPut, "/api/api/personal-snapshots/erke", nil))

	if response.Code != http.StatusNotFound {
		t.Fatalf("unmatched route status=%d, want %d", response.Code, http.StatusNotFound)
	}
	if body := response.Body.String(); body == "" {
		t.Fatal("router-level 404 must keep gin default body")
	}
}

func TestRequestTraceMiddlewarePreservesRedirectStatus(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(RequestTraceMiddleware())
	router.GET("/api/redirect", func(c *gin.Context) {
		c.Redirect(http.StatusFound, "/target")
	})

	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/redirect", nil))

	if response.Code != http.StatusFound {
		t.Fatalf("status=%d, want %d", response.Code, http.StatusFound)
	}
	if got := response.Header().Get("Location"); got != "/target" {
		t.Fatalf("redirect location=%q, want %q", got, "/target")
	}
}
