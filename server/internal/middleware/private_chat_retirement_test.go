package middleware

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

// privateChatPaths 覆盖私聊接口组的全部形态：列表、拉取、发送、已读、未读数、
// SSE 实时通道和附件下载，以及带尾斜杠的等价路径。
var privateChatPaths = []string{
	"/api/messages",
	"/api/messages/",
	"/api/messages/conversations",
	"/api/messages/conversations/7",
	"/api/messages/conversations/7/read",
	"/api/messages/events",
	"/api/messages/unread_count",
	"/api/messages/files/12",
	"/api/messages/users/9/conversation",
	"/api/messages/9/send-state",
	"/api/messages/9",
}

func TestPrivateChatRetirementGateBlocksEveryPrivateChatPath(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, method := range []string{http.MethodGet, http.MethodPost} {
		for _, path := range privateChatPaths {
			router := gin.New()
			router.Use(PrivateChatRetirementGate(true))
			router.Handle(method, path, func(c *gin.Context) {
				t.Errorf("私聊已关闭时处理器仍被执行: %s %s", method, path)
			})

			recorder := httptest.NewRecorder()
			router.ServeHTTP(recorder, httptest.NewRequest(method, path, nil))

			if recorder.Code != http.StatusGone {
				t.Fatalf("%s %s 状态码=%d，期望 410", method, path, recorder.Code)
			}
			var payload struct {
				Code  string `json:"code"`
				Error string `json:"error"`
			}
			if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
				t.Fatalf("%s %s 响应不是合法 JSON: %v", method, path, err)
			}
			if payload.Code != PrivateChatDisabledCode {
				t.Fatalf("%s %s 错误码=%q，期望 %q", method, path, payload.Code, PrivateChatDisabledCode)
			}
		}
	}
}

func TestPrivateChatRetirementGateLeavesOtherRoutesUntouched(t *testing.T) {
	gin.SetMode(gin.TestMode)
	// 包含前缀陷阱 /api/messages-archive：它不属于私聊接口组，不能被误伤。
	for _, path := range []string{
		"/api/messages-archive",
		"/api/messagesx",
		"/api/login",
		"/api/posts",
		"/api/notifications/unread_count",
		"/api/feedback/tickets/1/messages",
		"/health",
	} {
		router := gin.New()
		router.Use(PrivateChatRetirementGate(true))
		router.GET(path, func(c *gin.Context) { c.Status(http.StatusOK) })

		recorder := httptest.NewRecorder()
		router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))

		if recorder.Code != http.StatusOK {
			t.Fatalf("非私聊路径 %s 被误拦截: status=%d", path, recorder.Code)
		}
	}
}

func TestPrivateChatRetirementGatePassesThroughWhenEnabled(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, path := range privateChatPaths {
		router := gin.New()
		router.Use(PrivateChatRetirementGate(false))
		router.GET(path, func(c *gin.Context) { c.Status(http.StatusOK) })

		recorder := httptest.NewRecorder()
		router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))

		if recorder.Code != http.StatusOK {
			t.Fatalf("私聊开关未开启时 %s 应放行: status=%d", path, recorder.Code)
		}
	}
}

func TestPrivateChatRetirementGateStopsBeforeBodyRead(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	// 前置闸门 + 一个会读取请求体的下游中间件。关闭私聊时必须连下游中间件
	// 都不会执行，从而证明消息内容没有进入后端处理链路。
	router.Use(PrivateChatRetirementGate(true), func(c *gin.Context) {
		c.Request.Body = &countingRequestBody{reader: c.Request.Body}
	})
	router.POST("/api/messages/:user_id", func(c *gin.Context) {
		t.Fatal("私聊已关闭时发送处理器不应执行")
	})

	body := &countingRequestBody{reader: strings.NewReader(`{"content":"must-not-be-read"}`)}
	req := httptest.NewRequest(http.MethodPost, "/api/messages/9", nil)
	req.Body = body
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", "private-chat-disabled")
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusGone {
		t.Fatalf("关闭私聊后发送请求状态码=%d，期望 410，响应=%s", recorder.Code, recorder.Body.String())
	}
	if got := body.reads.Load(); got != 0 {
		t.Fatalf("关闭私聊后请求体被读取 %d 次，期望为 0", got)
	}
}
