package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestRetiredCourseCacheEndpointsRejectLegacyReadAndWrite(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := NewEduHandler(nil)
	router := gin.New()
	router.GET("/api/edu/courses/local", handler.RetiredCourseCache)
	router.POST("/api/edu/courses/sync", handler.RetiredCourseCache)

	testCases := []struct {
		name   string
		method string
		path   string
		body   string
	}{
		{
			name:   "历史读取接口不返回课程",
			method: http.MethodGet,
			path:   "/api/edu/courses/local?year=2026&semester=3",
		},
		{
			name:   "历史写入接口不接受课程上传",
			method: http.MethodPost,
			path:   "/api/edu/courses/sync",
			body:   `{"year":"2026","semester":3,"raw_json":"[{\"name\":\"课程\"}]"}`,
		},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			request := httptest.NewRequest(
				testCase.method,
				testCase.path,
				bytes.NewBufferString(testCase.body),
			)
			request.Header.Set("Content-Type", "application/json")
			router.ServeHTTP(recorder, request)

			if recorder.Code != http.StatusGone {
				t.Fatalf("status = %d, want %d", recorder.Code, http.StatusGone)
			}
			var body map[string]interface{}
			if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
				t.Fatalf("decode response: %v", err)
			}
			if body["code"] != legacyCourseCacheRetiredCode {
				t.Fatalf("code = %#v, want %q", body["code"], legacyCourseCacheRetiredCode)
			}
			if body["action"] != "upgrade_client" || body["retryable"] != false {
				t.Fatalf("unexpected retirement response: %#v", body)
			}
			if _, leaked := body["courses"]; leaked {
				t.Fatalf("retired endpoint must not return courses: %#v", body)
			}
		})
	}
}
