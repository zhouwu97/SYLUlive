package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/models"
)

func preferenceRequest(t *testing.T, handler gin.HandlerFunc, method, body string, userID uint) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(method, "/api/user/competition-preference", strings.NewReader(body))
	context.Request.Header.Set("Content-Type", "application/json")
	if userID != 0 {
		context.Set("user_id", userID)
	}
	handler(context)
	return recorder
}

func decodePreferenceResponse(t *testing.T, recorder *httptest.ResponseRecorder) competitionPreferenceResponse {
	t.Helper()
	var response competitionPreferenceResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func TestCompetitionPreferenceGetReturnsDefaultWhenUnset(t *testing.T) {
	db := newCompetitionTestDB(t)
	recorder := preferenceRequest(t, NewCompetitionHandler(db).GetCompetitionPreference, http.MethodGet, "", 1)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	response := decodePreferenceResponse(t, recorder)
	if response.Configured || response.ExperienceLevel != "beginner" || response.Goals == nil || len(response.Goals) != 0 {
		t.Fatalf("unexpected default response: %+v", response)
	}
}

func TestCompetitionPreferencePutThenGetAndUpdateSingleRow(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	first := `{
		"goals":[" resume ","ability","resume",""],
		"direction_tags":["程序设计"," 程序设计 ","数学建模"],
		"skill_tags":["Python","算法"],
		"preferred_roles":["developer","presenter"],
		"weekly_hours":7,
		"accept_long_term_training":true,
		"career_direction":" 后端开发 ",
		"experience_level":"participated"
	}`
	recorder := preferenceRequest(t, handler.PutCompetitionPreference, http.MethodPut, first, 11)
	if recorder.Code != http.StatusOK {
		t.Fatalf("first put status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	response := decodePreferenceResponse(t, recorder)
	if !response.Configured || strings.Join(response.Goals, ",") != "resume,ability" ||
		strings.Join(response.DirectionTags, ",") != "程序设计,数学建模" || response.CareerDirection != "后端开发" {
		t.Fatalf("unexpected normalized response: %+v", response)
	}

	second := `{"goals":["exploration"],"direction_tags":[],"skill_tags":[],"preferred_roles":["any"],"weekly_hours":3,"accept_long_term_training":false,"career_direction":"","experience_level":"beginner"}`
	recorder = preferenceRequest(t, handler.PutCompetitionPreference, http.MethodPut, second, 11)
	if recorder.Code != http.StatusOK {
		t.Fatalf("second put status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var count int64
	if err := db.Model(&models.UserCompetitionPreference{}).Where("user_id = ?", 11).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("preference rows=%d want=1", count)
	}
	recorder = preferenceRequest(t, handler.GetCompetitionPreference, http.MethodGet, "", 11)
	response = decodePreferenceResponse(t, recorder)
	if strings.Join(response.Goals, ",") != "exploration" || response.WeeklyHours != 3 {
		t.Fatalf("updated response: %+v", response)
	}
}

func TestCompetitionPreferenceIsIsolatedByCurrentUser(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	bodyA := `{"goals":["resume"],"experience_level":"beginner"}`
	bodyB := `{"goals":["ability"],"experience_level":"awarded"}`
	if got := preferenceRequest(t, handler.PutCompetitionPreference, http.MethodPut, bodyA, 21); got.Code != http.StatusOK {
		t.Fatal(got.Body.String())
	}
	if got := preferenceRequest(t, handler.PutCompetitionPreference, http.MethodPut, bodyB, 22); got.Code != http.StatusOK {
		t.Fatal(got.Body.String())
	}
	response := decodePreferenceResponse(t, preferenceRequest(t, handler.GetCompetitionPreference, http.MethodGet, "", 21))
	if strings.Join(response.Goals, ",") != "resume" || response.ExperienceLevel != "beginner" {
		t.Fatalf("user A read another preference: %+v", response)
	}
}

func TestCompetitionPreferenceRejectsInvalidValues(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db).PutCompetitionPreference
	tests := map[string]string{
		"too many goals":      `{"goals":["resume","ability","exploration","postgraduate"],"experience_level":"beginner"}`,
		"too many directions": `{"direction_tags":["1","2","3","4","5","6","7","8","9"],"experience_level":"beginner"}`,
		"too many skills":     `{"skill_tags":["1","2","3","4","5","6","7","8","9","10","11","12","13"],"experience_level":"beginner"}`,
		"unknown goal":        `{"goals":["score"],"experience_level":"beginner"}`,
		"unknown role":        `{"preferred_roles":["captain"],"experience_level":"beginner"}`,
		"weekly hours":        `{"weekly_hours":41,"experience_level":"beginner"}`,
		"unknown field":       `{"student_id":"25050001","experience_level":"beginner"}`,
	}
	for name, body := range tests {
		t.Run(name, func(t *testing.T) {
			recorder := preferenceRequest(t, handler, http.MethodPut, body, 31)
			if recorder.Code != http.StatusBadRequest {
				t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
			}
		})
	}
}

func TestCompetitionPreferenceCleansBeforeApplyingLimits(t *testing.T) {
	db := newCompetitionTestDB(t)
	values := []string{"Python", " Python ", "", "算法", "算法", "建模", "硬件", "设计", "文案", "答辩", "项目管理", "C++", "数据分析", "嵌入式"}
	payload, _ := json.Marshal(map[string]interface{}{"skill_tags": values, "experience_level": "beginner"})
	recorder := preferenceRequest(t, NewCompetitionHandler(db).PutCompetitionPreference, http.MethodPut, string(payload), 41)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	response := decodePreferenceResponse(t, recorder)
	if len(response.SkillTags) != 11 {
		t.Fatalf("cleaned skills=%v", response.SkillTags)
	}
}

func TestCompetitionPreferenceRequiresAuthentication(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	for _, test := range []struct {
		method  string
		body    string
		handler gin.HandlerFunc
	}{
		{http.MethodGet, "", handler.GetCompetitionPreference},
		{http.MethodPut, `{}`, handler.PutCompetitionPreference},
	} {
		recorder := preferenceRequest(t, test.handler, test.method, test.body, 0)
		if recorder.Code != http.StatusUnauthorized {
			t.Fatalf("method=%s status=%d body=%s", test.method, recorder.Code, recorder.Body.String())
		}
	}
}

func TestCompetitionPreferenceRejectsMultipleJSONObjects(t *testing.T) {
	db := newCompetitionTestDB(t)
	body := bytes.NewBufferString(`{"experience_level":"beginner"}{"experience_level":"awarded"}`).String()
	recorder := preferenceRequest(t, NewCompetitionHandler(db).PutCompetitionPreference, http.MethodPut, body, 51)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}
