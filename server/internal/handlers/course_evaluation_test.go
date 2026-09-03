package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
)

// newCourseEvaluationTestHandler 构造不依赖数据库的处理器。
// 参数校验、路由分发与错误码映射都不需要真实 DB，
// 一旦请求穿透到服务层会得到 course_evaluation_subject_unavailable，
// 正好用来区分"走到服务层"与"被参数校验拦下"。
func newCourseEvaluationTestHandler() *CourseEvaluationHandler {
	return NewCourseEvaluationHandler(nil)
}

func TestCourseEvaluationSubmitRejectsSchedulePrivateFields(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := newCourseEvaluationTestHandler()

	cases := []struct {
		name  string
		field string
	}{
		{name: "教室", field: "location"},
		{name: "周次", field: "weeks"},
		{name: "开始节次", field: "start_section"},
		{name: "结束节次", field: "end_section"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			ctx, _ := gin.CreateTestContext(recorder)
			body := `{"course_name":"高等数学A1","teacher_name":"张老师","star":5,` +
				`"comment":"很好","` + tc.field + `":"教学楼A101"}`
			ctx.Request = httptest.NewRequest(http.MethodPost, "/api/course-evaluations", strings.NewReader(body))
			ctx.Request.Header.Set("Content-Type", "application/json")
			ctx.Set("user_id", uint(1))

			handler.Submit(ctx)

			if recorder.Code != http.StatusBadRequest {
				t.Fatalf("课表私有字段 %s 应被拒绝，状态码=%d 响应=%s",
					tc.field, recorder.Code, recorder.Body.String())
			}
			assertCourseEvaluationCode(t, recorder, services.CodeInvalidCourseEvaluationInput)
		})
	}
}

func TestCourseEvaluationSubmitAcceptsWhitelistedFields(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := newCourseEvaluationTestHandler()

	recorder := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(recorder)
	ctx.Request = httptest.NewRequest(http.MethodPost, "/api/course-evaluations",
		strings.NewReader(`{"course_name":"高等数学A1","teacher_name":"张老师","star":5,"comment":"很好"}`))
	ctx.Request.Header.Set("Content-Type", "application/json")
	ctx.Set("user_id", uint(1))

	handler.Submit(ctx)

	// 白名单字段不应被参数校验拦下；请求应穿透到服务层并返回 409 服务不可用。
	if recorder.Code != http.StatusConflict {
		t.Fatalf("白名单字段应放行到服务层，状态码=%d 响应=%s", recorder.Code, recorder.Body.String())
	}
	assertCourseEvaluationCode(t, recorder, services.CodeCourseEvaluationSubjectUnavailable)
}

func TestCourseEvaluationRequiresAuthenticatedUser(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := newCourseEvaluationTestHandler()

	recorder := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(recorder)
	ctx.Request = httptest.NewRequest(http.MethodPost, "/api/course-evaluations",
		strings.NewReader(`{"course_name":"高等数学A1","teacher_name":"张老师","star":5}`))
	ctx.Request.Header.Set("Content-Type", "application/json")

	handler.Submit(ctx)

	if recorder.Code != http.StatusForbidden {
		t.Fatalf("未登录应返回 403，状态码=%d 响应=%s", recorder.Code, recorder.Body.String())
	}
	assertCourseEvaluationCode(t, recorder, services.CodeCourseEvaluationForbidden)
}

// TestCourseEvaluationResolveRoutePrecedesSubjectID 验证 resolve 路由优先于 /:id。
// 若注册顺序颠倒，/api/course-subjects/resolve 会被 GetSubject 命中，
// 因 "resolve" 无法解析为学科 ID 而返回 400。
func TestCourseEvaluationResolveRoutePrecedesSubjectID(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := newCourseEvaluationTestHandler()

	router := gin.New()
	subjects := router.Group("/api/course-subjects")
	subjects.GET("/resolve", func(c *gin.Context) {
		c.Set("user_id", uint(1))
		handler.Resolve(c)
	})
	subjects.GET("", handler.ListSubjects)
	subjects.GET("/:id", handler.GetSubject)

	recorder := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/course-subjects/resolve?course_name=高等数学A1&teacher_name=张老师", nil)
	router.ServeHTTP(recorder, req)

	if recorder.Code == http.StatusBadRequest {
		t.Fatalf("resolve 被 /:id 抢先命中，响应=%s", recorder.Body.String())
	}
	if recorder.Code != http.StatusConflict {
		t.Fatalf("resolve 应命中解析逻辑并返回 409 服务不可用，状态码=%d 响应=%s",
			recorder.Code, recorder.Body.String())
	}
	assertCourseEvaluationCode(t, recorder, services.CodeCourseEvaluationSubjectUnavailable)
}

func TestCourseEvaluationErrorMapsToBusinessCode(t *testing.T) {
	gin.SetMode(gin.TestMode)

	cases := []struct {
		name         string
		err          error
		wantCode     int
		wantBusiness string
	}{
		{
			name:         "revision 冲突映射为 409",
			err:          &services.CourseEvaluationError{Code: services.CodeCourseEvaluationRevisionConflict, Message: "评价已被修改"},
			wantCode:     http.StatusConflict,
			wantBusiness: services.CodeCourseEvaluationRevisionConflict,
		},
		{
			name:         "驳回原因缺失映射为 400",
			err:          &services.CourseEvaluationError{Code: services.CodeCourseEvaluationReasonRequired, Message: "请填写驳回原因"},
			wantCode:     http.StatusBadRequest,
			wantBusiness: services.CodeCourseEvaluationReasonRequired,
		},
		{
			name:         "候选需确认映射为 409",
			err:          &services.CourseEvaluationError{Code: services.CodeCourseEvaluationCandidateRequired, Message: "请选择候选学科"},
			wantCode:     http.StatusConflict,
			wantBusiness: services.CodeCourseEvaluationCandidateRequired,
		},
		{
			name:         "记录不存在映射为 404",
			err:          &services.CourseEvaluationError{Code: services.CodeCourseEvaluationNotFound, Message: "评价记录不存在"},
			wantCode:     http.StatusNotFound,
			wantBusiness: services.CodeCourseEvaluationNotFound,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			ctx, _ := gin.CreateTestContext(recorder)
			respondCourseEvaluationError(ctx, tc.err)
			if recorder.Code != tc.wantCode {
				t.Fatalf("状态码=%d，期望 %d", recorder.Code, tc.wantCode)
			}
			assertCourseEvaluationCode(t, recorder, tc.wantBusiness)
		})
	}
}

func assertCourseEvaluationCode(t *testing.T, recorder *httptest.ResponseRecorder, want string) {
	t.Helper()
	var payload struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatalf("响应不是合法 JSON: %v，内容=%s", err, recorder.Body.String())
	}
	if payload.Code != want {
		t.Fatalf("业务码=%q，期望 %q", payload.Code, want)
	}
}
