package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

// TestErkeGetScoresForwardsInternalServiceToken 校验二课转发会带上服务间认证头。
//
// Python 侧 /erke/scores 依赖 require_internal_service 做 fail-closed 认证，
// 服务端漏发该头会让接口整体 401/503，因此在这里把这条契约固化成测试。
func TestErkeGetScoresForwardsInternalServiceToken(t *testing.T) {
	gin.SetMode(gin.TestMode)

	var gotToken, gotPath string
	upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		gotToken = request.Header.Get("X-Internal-Service-Token")
		gotPath = request.URL.Path
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"success":true,"data":{"scores":[]}}`))
	}))
	defer upstream.Close()

	previousConfig := EduServiceConfig
	EduServiceConfig.BaseURL = upstream.URL
	EduServiceConfig.Token = "erke-test-token"
	defer func() { EduServiceConfig = previousConfig }()

	router := gin.New()
	router.POST("/api/erke/scores", NewErkeHandler(nil).GetScores)

	payload, err := json.Marshal(ErkeQueryInput{
		VpnUsername:  "vpn-user",
		VpnPassword:  "vpn-password",
		ErkeUsername: "2026000101",
		ErkePassword: "erke-password",
	})
	if err != nil {
		t.Fatalf("构造请求体失败: %v", err)
	}

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/api/erke/scores", bytes.NewReader(payload)))

	if recorder.Code != http.StatusOK {
		t.Fatalf("转发二课查询失败: status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if gotPath != "/erke/scores" {
		t.Fatalf("转发路径错误: %s", gotPath)
	}
	if gotToken != "erke-test-token" {
		t.Fatalf("未携带服务间认证头: got=%q", gotToken)
	}
}
