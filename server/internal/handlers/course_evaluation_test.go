package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
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

func TestCourseEvaluationSubjectDetailUsesTheSameRatingStatsAsList(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "course-evaluation.db")), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("获取测试数据库连接失败: %v", err)
	}
	defer sqlDB.Close()
	if err := db.AutoMigrate(&models.CourseSubject{}, &models.Teacher{}, &models.TeacherRating{}); err != nil {
		t.Fatalf("初始化测试数据库失败: %v", err)
	}

	subject := models.CourseSubject{
		Name:           "高等数学A1",
		NormalizedName: models.NormalizeCourseSubjectName("高等数学A1"),
		Verified:       true,
	}
	if err := db.Create(&subject).Error; err != nil {
		t.Fatalf("创建测试学科失败: %v", err)
	}
	teacherIDs := make([]uint, 0, 2)
	for _, name := range []string{"张老师", "李老师"} {
		teacher := models.Teacher{
			Name:            name,
			Course:          subject.Name,
			Verified:        true,
			CourseSubjectID: &subject.ID,
			NameNormalized:  models.NormalizeTeacherName(name),
		}
		if err := db.Create(&teacher).Error; err != nil {
			t.Fatalf("创建测试教师失败: %v", err)
		}
		teacherIDs = append(teacherIDs, teacher.ID)
	}
	for _, rating := range []models.TeacherRating{
		{TeacherID: teacherIDs[0], UserID: 1, Star: 5, Status: "normal"},
		{TeacherID: teacherIDs[1], UserID: 2, Star: 4, Status: "normal"},
		{TeacherID: teacherIDs[0], UserID: 3, Star: 1, Status: "pending"},
	} {
		if err := db.Create(&rating).Error; err != nil {
			t.Fatalf("创建测试评价失败: %v", err)
		}
	}

	handler := NewCourseEvaluationHandler(db)
	listRecorder := httptest.NewRecorder()
	listContext, _ := gin.CreateTestContext(listRecorder)
	listContext.Request = httptest.NewRequest(http.MethodGet, "/api/course-subjects", nil)
	handler.ListSubjects(listContext)
	if listRecorder.Code != http.StatusOK {
		t.Fatalf("学科列表状态码=%d，响应=%s", listRecorder.Code, listRecorder.Body.String())
	}
	var list []courseSubjectView
	if err := json.Unmarshal(listRecorder.Body.Bytes(), &list); err != nil {
		t.Fatalf("学科列表响应解析失败: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("学科列表数量=%d，期望 1", len(list))
	}

	detailRecorder := httptest.NewRecorder()
	detailContext, _ := gin.CreateTestContext(detailRecorder)
	detailContext.Request = httptest.NewRequest(
		http.MethodGet,
		"/api/course-subjects/"+strconv.FormatUint(uint64(subject.ID), 10),
		nil,
	)
	detailContext.Params = gin.Params{{Key: "id", Value: strconv.FormatUint(uint64(subject.ID), 10)}}
	handler.GetSubject(detailContext)
	if detailRecorder.Code != http.StatusOK {
		t.Fatalf("学科详情状态码=%d，响应=%s", detailRecorder.Code, detailRecorder.Body.String())
	}
	var detail courseSubjectDetailView
	if err := json.Unmarshal(detailRecorder.Body.Bytes(), &detail); err != nil {
		t.Fatalf("学科详情响应解析失败: %v", err)
	}

	if list[0].RatingCount != 2 || list[0].AverageStar != 4.5 || list[0].TeacherCount != 2 {
		t.Fatalf("学科列表统计异常: %+v", list[0])
	}
	if detail.RatingCount != list[0].RatingCount || detail.AverageStar != list[0].AverageStar || detail.TeacherCount != list[0].TeacherCount {
		t.Fatalf("学科详情统计未与列表统一: list=%+v detail=%+v", list[0], detail.courseSubjectView)
	}
	if detail.Name != subject.Name {
		t.Fatalf("学科详情名称=%q，期望 %q", detail.Name, subject.Name)
	}
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
