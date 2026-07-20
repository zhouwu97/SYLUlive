package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"shenliyuan/internal/ai"
)

func performScheduleRequest(t *testing.T, handler *AIScheduleHandler, body string) (int, map[string]interface{}) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.POST("/api/ai/schedule/windows", func(c *gin.Context) {
		c.Set("user_id", uint(42))
		handler.Windows(c)
	})
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/api/ai/schedule/windows", strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(recorder, request)
	var response map[string]interface{}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	return recorder.Code, response
}

func TestAIScheduleHandlerReturnsUnavailableWhenDisabled(t *testing.T) {
	status, response := performScheduleRequest(t, NewAIScheduleHandler(nil, false), `{}`)
	if status != http.StatusServiceUnavailable || response["code"] != "schedule_skill_disabled" {
		t.Fatalf("unexpected disabled response: status=%d body=%#v", status, response)
	}
}

func TestAIScheduleHandlerRejectsUnknownArguments(t *testing.T) {
	status, response := performScheduleRequest(t, NewAIScheduleHandler(ai.NewScheduleSkill(nil, nil), true), `{"scope":"today","minimum_free_minutes":60,"user_id":99}`)
	if status != http.StatusBadRequest || response["code"] != "invalid_schedule_request" {
		t.Fatalf("unexpected invalid response: status=%d body=%#v", status, response)
	}
}
