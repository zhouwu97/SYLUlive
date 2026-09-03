package handlers

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"

	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// courseEvaluationForbiddenFields 课表私有字段。
// 请求体一旦出现这些字段就整体拒绝，而不是忽略后继续保存，
// 保证教室、周次、节次等信息永远不会进入课程评价链路。
var courseEvaluationForbiddenFields = []string{
	"location",
	"weeks",
	"start_section",
	"end_section",
	"classroom",
	"section",
	"week",
	"day_of_week",
	"start_time",
	"end_time",
	"schedule",
	"timetable",
}

// CourseEvaluationHandler 课程评价 HTTP 层。
// 只负责参数解析、权限取值、错误码映射与视图组装，
// 所有业务规则都由 CourseEvaluationService 承载。
type CourseEvaluationHandler struct {
	db      *gorm.DB
	service *services.CourseEvaluationService
}

func NewCourseEvaluationHandler(db *gorm.DB) *CourseEvaluationHandler {
	return &CourseEvaluationHandler{db: db, service: services.NewCourseEvaluationService(db)}
}

// courseSubjectView 公开学科视图。学科本身不承载评分，统计由教师评价聚合而来。
type courseSubjectView struct {
	ID           uint    `json:"id"`
	Name         string  `json:"name"`
	TeacherCount int     `json:"teacher_count"`
	AverageStar  float64 `json:"average_star"`
	RatingCount  int     `json:"rating_count"`
}

type courseSubjectTeacherView struct {
	ID          uint    `json:"id"`
	Name        string  `json:"name"`
	RatingCount int     `json:"rating_count"`
	AverageStar float64 `json:"average_star"`
}

type courseSubjectDetailView struct {
	courseSubjectView
	Teachers []courseSubjectTeacherView `json:"teachers"`
}

// respondCourseEvaluationError 把服务层错误统一映射为稳定业务码。
// 业务码由客户端直接消费，不依赖 HTTP 文本或数据库错误信息。
func respondCourseEvaluationError(c *gin.Context, err error) {
	var businessErr *services.CourseEvaluationError
	if errors.As(err, &businessErr) {
		c.JSON(services.CourseEvaluationHTTPStatus(businessErr.Code), gin.H{
			"error": businessErr.Message,
			"code":  businessErr.Code,
		})
		return
	}
	if errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusNotFound, gin.H{
			"error": "评价记录不存在",
			"code":  services.CodeCourseEvaluationNotFound,
		})
		return
	}
	c.JSON(http.StatusInternalServerError, gin.H{
		"error": "课程评价服务异常，请稍后重试",
		"code":  services.CodeCourseEvaluationSubjectUnavailable,
	})
}

// courseEvaluationUserID 取出中间件写入的当前用户 ID。
func courseEvaluationUserID(c *gin.Context) (uint, bool) {
	value, exists := c.Get("user_id")
	if !exists || value == nil {
		return 0, false
	}
	switch uid := value.(type) {
	case uint:
		return uid, uid != 0
	case int:
		if uid <= 0 {
			return 0, false
		}
		return uint(uid), true
	case int64:
		if uid <= 0 {
			return 0, false
		}
		return uint(uid), true
	case float64:
		if uid <= 0 {
			return 0, false
		}
		return uint(uid), true
	default:
		return 0, false
	}
}

// requireCourseEvaluationUser 统一处理"未登录"分支。
func requireCourseEvaluationUser(c *gin.Context) (uint, bool) {
	userID, ok := courseEvaluationUserID(c)
	if !ok {
		respondCourseEvaluationError(c, &services.CourseEvaluationError{
			Code:    services.CodeCourseEvaluationForbidden,
			Message: "请先登录",
		})
		return 0, false
	}
	return userID, true
}

// decodeCourseEvaluationBody 读取并校验请求体：
// 先拦截课表私有字段，再反序列化，避免私有信息被静默丢弃后继续入库。
func decodeCourseEvaluationBody(c *gin.Context, dst interface{}) error {
	if c.Request == nil || c.Request.Body == nil {
		return &services.CourseEvaluationError{
			Code:    services.CodeInvalidCourseEvaluationInput,
			Message: "请求体不能为空",
		}
	}
	raw, err := io.ReadAll(io.LimitReader(c.Request.Body, 1<<20))
	if err != nil {
		return &services.CourseEvaluationError{
			Code:    services.CodeInvalidCourseEvaluationInput,
			Message: "读取请求体失败",
			Err:     err,
		}
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return &services.CourseEvaluationError{
			Code:    services.CodeInvalidCourseEvaluationInput,
			Message: "请求体不能为空",
		}
	}
	if field, ok := findForbiddenScheduleField(raw); ok {
		return &services.CourseEvaluationError{
			Code:    services.CodeInvalidCourseEvaluationInput,
			Message: fmt.Sprintf("课表私有字段 %s 不允许提交", field),
		}
	}
	if err := json.Unmarshal(raw, dst); err != nil {
		return &services.CourseEvaluationError{
			Code:    services.CodeInvalidCourseEvaluationInput,
			Message: "请求体格式错误",
			Err:     err,
		}
	}
	return nil
}

// findForbiddenScheduleField 在原始请求体中查找课表私有字段。
func findForbiddenScheduleField(raw []byte) (string, bool) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return "", false
	}
	for _, forbidden := range courseEvaluationForbiddenFields {
		if _, ok := fields[forbidden]; ok {
			return forbidden, true
		}
	}
	return "", false
}

// parseCourseEvaluationID 解析路径参数中的记录 ID。
func parseCourseEvaluationID(c *gin.Context) (uint, bool) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || id == 0 {
		respondCourseEvaluationError(c, &services.CourseEvaluationError{
			Code:    services.CodeInvalidCourseEvaluationInput,
			Message: "无效的评价记录 ID",
		})
		return 0, false
	}
	return uint(id), true
}

// parseCourseEvaluationPage 解析游标分页参数。
func parseCourseEvaluationPage(c *gin.Context) (int, string) {
	limit := 0
	if raw := c.Query("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil {
			limit = parsed
		}
	}
	return limit, c.Query("cursor")
}

// ListSubjects 公开学科列表。只返回已审核学科，统计只累计已审核教师的正常评价。
func (h *CourseEvaluationHandler) ListSubjects(c *gin.Context) {
	var rows []courseSubjectView
	err := h.db.Table("course_subjects cs").
		Select(`cs.id AS id,
			cs.name AS name,
			COUNT(DISTINCT t.id) AS teacher_count,
			COUNT(tr.id) AS rating_count,
			COALESCE(AVG(CAST(tr.star AS FLOAT)), 0) AS average_star`).
		Joins("LEFT JOIN teachers t ON t.course_subject_id = cs.id AND t.verified = ?", true).
		Joins("LEFT JOIN teacher_ratings tr ON tr.teacher_id = t.id AND tr.status = ? AND tr.deleted_at IS NULL", "normal").
		Where("cs.verified = ?", true).
		Group("cs.id").
		Order("rating_count DESC, average_star DESC, cs.id ASC").
		Find(&rows).Error
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "获取学科列表失败",
			"code":  services.CodeCourseEvaluationSubjectUnavailable,
		})
		return
	}
	if rows == nil {
		rows = []courseSubjectView{}
	}
	c.JSON(http.StatusOK, rows)
}

// GetSubject 公开学科详情。只返回已审核学科及其已审核教师。
func (h *CourseEvaluationHandler) GetSubject(c *gin.Context) {
	subjectID, ok := parseCourseEvaluationID(c)
	if !ok {
		return
	}
	var subject courseSubjectView
	err := h.db.Table("course_subjects").
		Select("id, name").
		Where("id = ? AND verified = ?", subjectID, true).
		First(&subject).Error
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			respondCourseEvaluationError(c, &services.CourseEvaluationError{
				Code:    services.CodeCourseEvaluationNotFound,
				Message: "学科不存在或未通过审核",
			})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "获取学科失败",
			"code":  services.CodeCourseEvaluationSubjectUnavailable,
		})
		return
	}

	var teachers []courseSubjectTeacherView
	err = h.db.Table("teachers t").
		Select(`t.id AS id,
			t.name AS name,
			COUNT(tr.id) AS rating_count,
			COALESCE(AVG(CAST(tr.star AS FLOAT)), 0) AS average_star`).
		Joins("LEFT JOIN teacher_ratings tr ON tr.teacher_id = t.id AND tr.status = ? AND tr.deleted_at IS NULL", "normal").
		Where("t.course_subject_id = ? AND t.verified = ?", subjectID, true).
		Group("t.id").
		Order("average_star DESC, rating_count DESC, t.id ASC").
		Find(&teachers).Error
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "获取学科教师失败",
			"code":  services.CodeCourseEvaluationSubjectUnavailable,
		})
		return
	}
	if teachers == nil {
		teachers = []courseSubjectTeacherView{}
	}
	subject.TeacherCount = len(teachers)

	c.JSON(http.StatusOK, courseSubjectDetailView{
		courseSubjectView: subject,
		Teachers:          teachers,
	})
}

// Resolve 解析课程名与教师名。
// 返回 200 并携带候选列表：需要用户确认时由 requires_confirmation 表达，
// 不用 4xx，因为候选信息本身就是正常响应体的一部分。
func (h *CourseEvaluationHandler) Resolve(c *gin.Context) {
	userID, ok := requireCourseEvaluationUser(c)
	if !ok {
		return
	}
	courseName := c.Query("course_name")
	teacherName := c.Query("teacher_name")
	result, err := h.service.Resolve(userID, courseName, teacherName)
	if err != nil {
		respondCourseEvaluationError(c, err)
		return
	}
	c.JSON(http.StatusOK, result)
}

// Submit 提交或复用当前用户的课程评价。
func (h *CourseEvaluationHandler) Submit(c *gin.Context) {
	userID, ok := requireCourseEvaluationUser(c)
	if !ok {
		return
	}
	var input services.SubmitInput
	if err := decodeCourseEvaluationBody(c, &input); err != nil {
		respondCourseEvaluationError(c, err)
		return
	}
	view, err := h.service.Submit(userID, input)
	if err != nil {
		respondCourseEvaluationError(c, err)
		return
	}
	c.JSON(http.StatusOK, view)
}

// ListMine 分页读取当前用户的课程评价记录。
func (h *CourseEvaluationHandler) ListMine(c *gin.Context) {
	userID, ok := requireCourseEvaluationUser(c)
	if !ok {
		return
	}
	limit, cursor := parseCourseEvaluationPage(c)
	page, err := h.service.ListMine(userID, limit, cursor)
	if err != nil {
		respondCourseEvaluationError(c, err)
		return
	}
	c.JSON(http.StatusOK, page)
}

// Update 编辑既有课程评价。published 记录直接改公开评价，其余回到 pending 重新审核。
func (h *CourseEvaluationHandler) Update(c *gin.Context) {
	userID, ok := requireCourseEvaluationUser(c)
	if !ok {
		return
	}
	submissionID, ok := parseCourseEvaluationID(c)
	if !ok {
		return
	}
	var input services.SubmitInput
	if err := decodeCourseEvaluationBody(c, &input); err != nil {
		respondCourseEvaluationError(c, err)
		return
	}
	view, err := h.service.Update(userID, submissionID, input)
	if err != nil {
		respondCourseEvaluationError(c, err)
		return
	}
	c.JSON(http.StatusOK, view)
}

// ListPending 管理员读取待审核列表。
func (h *CourseEvaluationHandler) ListPending(c *gin.Context) {
	limit, cursor := parseCourseEvaluationPage(c)
	page, err := h.service.ListPending(limit, cursor)
	if err != nil {
		respondCourseEvaluationError(c, err)
		return
	}
	c.JSON(http.StatusOK, page)
}

// Approve 管理员审核通过。revision 由请求体携带，过期返回 409。
func (h *CourseEvaluationHandler) Approve(c *gin.Context) {
	adminID, ok := courseEvaluationUserID(c)
	if !ok {
		respondCourseEvaluationError(c, &services.CourseEvaluationError{
			Code:    services.CodeCourseEvaluationForbidden,
			Message: "无权审核课程评价",
		})
		return
	}
	submissionID, ok := parseCourseEvaluationID(c)
	if !ok {
		return
	}
	var body struct {
		Revision int `json:"revision"`
	}
	if err := decodeCourseEvaluationBody(c, &body); err != nil {
		respondCourseEvaluationError(c, err)
		return
	}
	view, err := h.service.Approve(adminID, submissionID, body.Revision)
	if err != nil {
		respondCourseEvaluationError(c, err)
		return
	}
	c.JSON(http.StatusOK, view)
}

// Reject 管理员驳回。原因必须 1-500 字符，驳回后记录转入 needs_edit。
func (h *CourseEvaluationHandler) Reject(c *gin.Context) {
	adminID, ok := courseEvaluationUserID(c)
	if !ok {
		respondCourseEvaluationError(c, &services.CourseEvaluationError{
			Code:    services.CodeCourseEvaluationForbidden,
			Message: "无权审核课程评价",
		})
		return
	}
	submissionID, ok := parseCourseEvaluationID(c)
	if !ok {
		return
	}
	var body struct {
		Revision int    `json:"revision"`
		Reason   string `json:"reason"`
	}
	if err := decodeCourseEvaluationBody(c, &body); err != nil {
		respondCourseEvaluationError(c, err)
		return
	}
	view, err := h.service.Reject(adminID, submissionID, body.Revision, body.Reason)
	if err != nil {
		respondCourseEvaluationError(c, err)
		return
	}
	c.JSON(http.StatusOK, view)
}
