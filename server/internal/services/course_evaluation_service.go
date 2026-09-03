package services

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// 课程评价的稳定业务错误码。客户端据此映射到已有状态，
// 不依赖 HTTP 文本或数据库错误信息。
const (
	CodeInvalidCourseEvaluationInput       = "invalid_course_evaluation_input"
	CodeCourseEvaluationCandidateRequired  = "course_subject_candidate_required"
	CodeCourseEvaluationRevisionConflict   = "course_evaluation_revision_conflict"
	CodeCourseEvaluationForbidden          = "course_evaluation_forbidden"
	CodeCourseEvaluationReasonRequired     = "course_evaluation_rejection_reason_required"
	CodeCourseEvaluationNotFound           = "course_evaluation_not_found"
	CodeCourseEvaluationNotPending         = "course_evaluation_not_pending"
	CodeCourseEvaluationSubjectUnavailable = "course_evaluation_subject_unavailable"
)

// CourseEvaluationError 承载稳定业务码与服务内部错误。
type CourseEvaluationError struct {
	Code    string
	Message string
	Err     error
}

func (e *CourseEvaluationError) Error() string {
	if e.Err != nil {
		return fmt.Sprintf("%s: %v", e.Message, e.Err)
	}
	return e.Message
}

func (e *CourseEvaluationError) Unwrap() error { return e.Err }

// CourseEvaluationHTTPStatus 把业务码映射为 HTTP 状态码。
func CourseEvaluationHTTPStatus(code string) int {
	switch code {
	case CodeInvalidCourseEvaluationInput, CodeCourseEvaluationReasonRequired:
		return 400
	case CodeCourseEvaluationForbidden:
		return 403
	case CodeCourseEvaluationNotFound:
		return 404
	case CodeCourseEvaluationRevisionConflict, CodeCourseEvaluationCandidateRequired,
		CodeCourseEvaluationNotPending, CodeCourseEvaluationSubjectUnavailable:
		return 409
	default:
		return 500
	}
}

func courseEvalErr(code, message string, err error) *CourseEvaluationError {
	return &CourseEvaluationError{Code: code, Message: message, Err: err}
}

// CourseSubjectCandidate 学科候选。
type CourseSubjectCandidate struct {
	ID       uint   `json:"id"`
	Name     string `json:"name"`
	Verified bool   `json:"verified"`
	Match    string `json:"match"`
}

// TeacherCandidate 教师候选。
type TeacherCandidate struct {
	ID       uint   `json:"id"`
	Name     string `json:"name"`
	Verified bool   `json:"verified"`
	Match    string `json:"match"`
}

// ResolveResult 解析结果。RequiresConfirmation 为 true 时必须由用户选择候选后再提交。
type ResolveResult struct {
	CourseName           string                   `json:"course_name"`
	TeacherName          string                   `json:"teacher_name"`
	CourseSubjects       []CourseSubjectCandidate `json:"course_subjects"`
	Teachers             []TeacherCandidate       `json:"teachers"`
	SelectedSubjectID    *uint                    `json:"selected_course_subject_id,omitempty"`
	SelectedTeacherID    *uint                    `json:"selected_teacher_id,omitempty"`
	RequiresConfirmation bool                     `json:"requires_confirmation"`
	Code                 string                   `json:"code,omitempty"`
	Submission           *SubmissionView          `json:"submission,omitempty"`
}

// SubmitInput 用户主动确认后的提交输入。
// 刻意不包含教室、周次、节次等课表私有字段。
type SubmitInput struct {
	CourseName      string `json:"course_name"`
	CourseSubjectID *uint  `json:"course_subject_id"`
	TeacherName     string `json:"teacher_name"`
	TeacherID       *uint  `json:"teacher_id"`
	Star            int    `json:"star"`
	Comment         string `json:"comment"`
	Revision        int    `json:"revision"`
}

// SubmissionView 提交记录的对外视图。
type SubmissionView struct {
	ID                  uint      `json:"id"`
	UserID              uint      `json:"user_id"`
	CourseName          string    `json:"course_name"`
	CourseSubjectID     *uint     `json:"course_subject_id,omitempty"`
	CourseSubjectName   string    `json:"course_subject_name,omitempty"`
	TeacherName         string    `json:"teacher_name"`
	TeacherID           *uint     `json:"teacher_id,omitempty"`
	Star                int       `json:"star"`
	Comment             string    `json:"comment"`
	Status              string    `json:"status"`
	Source              string    `json:"source"`
	Revision            int       `json:"revision"`
	ReviewReason        string    `json:"review_reason,omitempty"`
	TeacherRatingID     *uint     `json:"teacher_rating_id,omitempty"`
	ProposedCourseName  string    `json:"proposed_course_name,omitempty"`
	ProposedTeacherName string    `json:"proposed_teacher_name,omitempty"`
	CreatedAt           time.Time `json:"created_at"`
	UpdatedAt           time.Time `json:"updated_at"`

	// 审核端展示用的派生字段
	WillCreateSubject bool   `json:"will_create_subject"`
	ReviewerName      string `json:"reviewer_name,omitempty"`
}

// SubmissionPage 游标分页结果。
type SubmissionPage struct {
	Items      []SubmissionView `json:"items"`
	NextCursor string           `json:"next_cursor,omitempty"`
	HasMore    bool             `json:"has_more"`
}

const courseEvaluationDefaultPageSize = 20
const courseEvaluationMaxPageSize = 50

// CourseEvaluationService 课程评价状态机。
type CourseEvaluationService struct {
	db *gorm.DB
}

func NewCourseEvaluationService(db *gorm.DB) *CourseEvaluationService {
	return &CourseEvaluationService{db: db}
}

// validateInput 校验并规范化提交输入。
func validateInput(in SubmitInput) (SubmitInput, error) {
	in.CourseName = strings.TrimSpace(in.CourseName)
	in.TeacherName = strings.TrimSpace(in.TeacherName)
	in.Comment = strings.TrimSpace(in.Comment)
	if in.CourseName == "" {
		return in, courseEvalErr(CodeInvalidCourseEvaluationInput, "课程名不能为空", nil)
	}
	if in.TeacherName == "" {
		return in, courseEvalErr(CodeInvalidCourseEvaluationInput, "教师名不能为空", nil)
	}
	if in.Star < 1 || in.Star > 5 {
		return in, courseEvalErr(CodeInvalidCourseEvaluationInput, "星级必须为 1-5", nil)
	}
	if models.CourseEvaluationCommentLength(in.Comment) > models.CourseEvaluationCommentMaxRunes {
		return in, courseEvalErr(CodeInvalidCourseEvaluationInput,
			fmt.Sprintf("评论不能超过 %d 字", models.CourseEvaluationCommentMaxRunes), nil)
	}
	if len([]rune(in.CourseName)) > models.CourseSubjectNameMaxLength {
		return in, courseEvalErr(CodeInvalidCourseEvaluationInput, "课程名过长", nil)
	}
	return in, nil
}

// Resolve 解析课程名与教师名，返回候选或当前用户的既有提交。
// 候选多于一个、或候选来自别名/包含关系时要求用户显式确认。
func (s *CourseEvaluationService) Resolve(userID uint, courseName, teacherName string) (*ResolveResult, error) {
	if s == nil || s.db == nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "评价服务不可用", nil)
	}
	courseName = strings.TrimSpace(courseName)
	teacherName = strings.TrimSpace(teacherName)
	if courseName == "" || teacherName == "" {
		return nil, courseEvalErr(CodeInvalidCourseEvaluationInput, "课程名与教师名不能为空", nil)
	}

	result := &ResolveResult{
		CourseName:     courseName,
		TeacherName:    teacherName,
		CourseSubjects: []CourseSubjectCandidate{},
		Teachers:       []TeacherCandidate{},
	}

	subjects, err := s.resolveSubjects(courseName)
	if err != nil {
		return nil, err
	}
	result.CourseSubjects = subjects

	if len(subjects) == 1 && subjects[0].Match == string(models.CourseSubjectMatchExact) {
		id := subjects[0].ID
		result.SelectedSubjectID = &id
		result.Teachers, err = s.resolveTeachers(id, teacherName)
		if err != nil {
			return nil, err
		}
		if len(result.Teachers) == 1 && result.Teachers[0].Match == "exact" {
			tid := result.Teachers[0].ID
			result.SelectedTeacherID = &tid
		}
	}

	// 需要确认的条件：多个候选，或唯一候选来自别名/包含关系。
	if len(subjects) != 1 || subjects[0].Match != string(models.CourseSubjectMatchExact) {
		result.RequiresConfirmation = true
		result.Code = CodeCourseEvaluationCandidateRequired
	}

	if userID != 0 {
		existing, err := s.findSubmissionByDedup(userID, courseName, teacherName)
		if err != nil {
			return nil, err
		}
		if existing != nil {
			view, err := s.toSubmissionView(existing)
			if err != nil {
				return nil, err
			}
			result.Submission = view
		}
	}
	return result, nil
}

// resolveSubjects 依次按精确、别名、包含关系收集学科候选。
func (s *CourseEvaluationService) resolveSubjects(courseName string) ([]CourseSubjectCandidate, error) {
	normalized := models.NormalizeCourseSubjectName(courseName)
	seen := map[uint]CourseSubjectCandidate{}

	var exact []models.CourseSubject
	if err := s.db.Where("normalized_name = ?", normalized).
		Order("verified DESC, id ASC").Limit(courseEvaluationMaxPageSize).Find(&exact).Error; err != nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取学科失败", err)
	}
	for _, subject := range exact {
		seen[subject.ID] = CourseSubjectCandidate{
			ID: subject.ID, Name: subject.Name, Verified: subject.Verified,
			Match: string(models.CourseSubjectMatchExact),
		}
	}

	if len(seen) == 0 {
		var aliases []models.CourseSubjectAlias
		if err := s.db.Where("normalized_alias = ?", normalized).
			Order("id ASC").Limit(courseEvaluationMaxPageSize).Find(&aliases).Error; err != nil {
			return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取学科别名失败", err)
		}
		for _, alias := range aliases {
			if _, ok := seen[alias.CourseSubjectID]; ok {
				continue
			}
			var subject models.CourseSubject
			if err := s.db.First(&subject, alias.CourseSubjectID).Error; err != nil {
				continue
			}
			seen[subject.ID] = CourseSubjectCandidate{
				ID: subject.ID, Name: subject.Name, Verified: subject.Verified,
				Match: string(models.CourseSubjectMatchAlias),
			}
		}
	}

	if len(seen) == 0 && len([]rune(normalized)) >= 2 {
		var contains []models.CourseSubject
		if err := s.db.Where("normalized_name LIKE ?", "%"+escapeLike(normalized)+"%").
			Order("verified DESC, id ASC").Limit(courseEvaluationMaxPageSize).Find(&contains).Error; err != nil {
			return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取学科失败", err)
		}
		for _, subject := range contains {
			seen[subject.ID] = CourseSubjectCandidate{
				ID: subject.ID, Name: subject.Name, Verified: subject.Verified,
				Match: string(models.CourseSubjectMatchContains),
			}
		}
	}

	out := make([]CourseSubjectCandidate, 0, len(seen))
	for _, c := range seen {
		out = append(out, c)
	}
	return out, nil
}

// resolveTeachers 在指定学科内按规范化名称解析教师候选。
func (s *CourseEvaluationService) resolveTeachers(subjectID uint, teacherName string) ([]TeacherCandidate, error) {
	normalized := models.NormalizeTeacherName(teacherName)
	if normalized == "" || subjectID == 0 {
		return []TeacherCandidate{}, nil
	}
	var teachers []models.Teacher
	if err := s.db.Where("course_subject_id = ? AND name_normalized = ?", subjectID, normalized).
		Order("verified DESC, id ASC").Limit(courseEvaluationMaxPageSize).Find(&teachers).Error; err != nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取教师失败", err)
	}
	out := make([]TeacherCandidate, 0, len(teachers))
	for _, t := range teachers {
		out = append(out, TeacherCandidate{ID: t.ID, Name: t.Name, Verified: t.Verified, Match: "exact"})
	}
	return out, nil
}

func (s *CourseEvaluationService) findSubmissionByDedup(userID uint, courseName, teacherName string) (*models.CourseEvaluationSubmission, error) {
	key := models.CourseEvaluationDedupKey(userID, courseName, teacherName)
	var submission models.CourseEvaluationSubmission
	err := s.db.Where("user_id = ? AND dedup_key = ?", userID, key).First(&submission).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取提交记录失败", err)
	}
	return &submission, nil
}

// Submit 创建或复用当前用户的提交记录。
// 已审核学科 + 已审核教师直接发布并 upsert 教师评价；否则保持 pending 等待审核。
func (s *CourseEvaluationService) Submit(userID uint, input SubmitInput) (*SubmissionView, error) {
	if s == nil || s.db == nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "评价服务不可用", nil)
	}
	if userID == 0 {
		return nil, courseEvalErr(CodeCourseEvaluationForbidden, "请先登录", nil)
	}
	input, err := validateInput(input)
	if err != nil {
		return nil, err
	}

	var view *SubmissionView
	err = s.db.Transaction(func(tx *gorm.DB) error {
		existing, err := s.findSubmissionByDedupTx(tx, userID, input.CourseName, input.TeacherName)
		if err != nil {
			return err
		}
		submission := models.CourseEvaluationSubmission{
			UserID:      userID,
			DedupKey:    models.CourseEvaluationDedupKey(userID, input.CourseName, input.TeacherName),
			Source:      models.CourseEvaluationSourceSchedule,
			CourseName:  input.CourseName,
			TeacherName: input.TeacherName,
			Star:        input.Star,
			Comment:     input.Comment,
			Status:      models.CourseEvaluationStatusPending,
			Revision:    1,
		}
		if existing != nil {
			submission = *existing
		}
		view, err = s.applySubmission(tx, &submission, input, false)
		return err
	})
	if err != nil {
		return nil, err
	}
	return view, nil
}

// Update 编辑既有提交记录。
// published 记录直接改链接的教师评价并保持 published；
// pending/needs_edit 递增 revision 并回到 pending 重新审核。
func (s *CourseEvaluationService) Update(userID, submissionID uint, input SubmitInput) (*SubmissionView, error) {
	if s == nil || s.db == nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "评价服务不可用", nil)
	}
	if userID == 0 {
		return nil, courseEvalErr(CodeCourseEvaluationForbidden, "请先登录", nil)
	}
	input, err := validateInput(input)
	if err != nil {
		return nil, err
	}

	var view *SubmissionView
	err = s.db.Transaction(func(tx *gorm.DB) error {
		var submission models.CourseEvaluationSubmission
		if err := tx.Where("id = ? AND user_id = ?", submissionID, userID).First(&submission).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return courseEvalErr(CodeCourseEvaluationNotFound, "评价记录不存在", nil)
			}
			return courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取评价记录失败", err)
		}
		if input.Revision != 0 && input.Revision != submission.Revision {
			return courseEvalErr(CodeCourseEvaluationRevisionConflict, "评价已被更新，请刷新后重试", nil)
		}
		view, err = s.applySubmission(tx, &submission, input, true)
		return err
	})
	if err != nil {
		return nil, err
	}
	return view, nil
}

// applySubmission 是 Submit 与 Update 共用的核心状态机。
//
// 规则：
//   - 已审核学科 + 已审核教师：upsert 教师评价并置 published；
//   - 缺学科或缺教师：只保存 pending，不创建公开实体、教师或评价；
//   - 候选不确定：返回 course_subject_candidate_required 要求用户确认；
//   - 不信任客户端提供的任意教师 ID，只接受属于选定学科且已审核的教师。
func (s *CourseEvaluationService) applySubmission(tx *gorm.DB, submission *models.CourseEvaluationSubmission, input SubmitInput, isUpdate bool) (*SubmissionView, error) {
	subject, candidates, err := s.selectSubject(tx, input)
	if err != nil {
		return nil, err
	}
	// 存在候选但无法唯一确定：要求用户确认后再提交，不自动选中。
	// 候选为空时才走"新建学科"的 pending 路径。
	if subject == nil && len(candidates) > 0 {
		return nil, courseEvalErr(CodeCourseEvaluationCandidateRequired,
			"存在多个候选学科，请选择后再提交", nil)
	}

	if isUpdate {
		wasPublished := submission.Status == models.CourseEvaluationStatusPublished
		if !wasPublished {
			submission.Revision++
			submission.ReviewedBy = nil
			submission.ReviewedAt = nil
			submission.ReviewReason = ""
			submission.Status = models.CourseEvaluationStatusPending
		}
	}

	submission.CourseName = input.CourseName
	submission.TeacherName = input.TeacherName
	submission.Star = input.Star
	submission.Comment = input.Comment
	submission.Source = models.CourseEvaluationSourceSchedule

	if subject == nil {
		// 缺学科：只保留用户提议，不创建公开实体。
		submission.CourseSubjectID = nil
		submission.CourseSubjectName = ""
		submission.ProposedCourseName = input.CourseName
		submission.Status = models.CourseEvaluationStatusPending
		submission.TeacherRatingID = nil
		submission.TeacherID = nil
	} else {
		submission.CourseSubjectID = &subject.ID
		submission.CourseSubjectName = subject.Name
		submission.ProposedCourseName = ""
	}

	var teacher *models.Teacher
	if subject != nil {
		teacher, err = s.selectTeacher(tx, subject, input)
		if err != nil {
			return nil, err
		}
	}

	switch {
	case teacher == nil:
		submission.TeacherID = nil
		submission.ProposedTeacherName = input.TeacherName
		submission.Status = models.CourseEvaluationStatusPending
		submission.TeacherRatingID = nil
	case subject != nil && subject.Verified && teacher.Verified:
		// 已审核学科+已审核教师：先标记为已发布，保存获得稳定 ID 后再 upsert 教师评价。
		submission.TeacherID = &teacher.ID
		submission.ProposedTeacherName = ""
		submission.Status = models.CourseEvaluationStatusPublished
	default:
		// 学科或教师未审核：保持 pending，只记录关联意图。
		submission.TeacherID = &teacher.ID
		submission.Status = models.CourseEvaluationStatusPending
	}

	// 先保存提交记录以获得稳定 ID。新建提交在关联教师评价前必须已有 ID，
	// 否则教师评价的 CourseEvaluationSubmissionID 会悬空指向 0，破坏双向关联。
	if err := tx.Save(submission).Error; err != nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "保存评价失败", err)
	}

	// 已审核学科+已审核教师：upsert 教师评价并回填双向关联。
	if subject != nil && teacher != nil && subject.Verified && teacher.Verified {
		rating, err := upsertTeacherRating(tx, submission.UserID, teacher.ID, submission)
		if err != nil {
			return nil, err
		}
		submission.TeacherRatingID = &rating.ID
		if err := tx.Save(submission).Error; err != nil {
			return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "保存评价失败", err)
		}
	}

	return s.toSubmissionView(submission)
}

// selectSubject 确定学科。返回 (nil, candidates>0, nil) 表示需要用户确认。
func (s *CourseEvaluationService) selectSubject(tx *gorm.DB, input SubmitInput) (*models.CourseSubject, []CourseSubjectCandidate, error) {
	candidates, err := s.resolveSubjectsTx(tx, input.CourseName)
	if err != nil {
		return nil, nil, err
	}
	if input.CourseSubjectID != nil && *input.CourseSubjectID != 0 {
		var subject models.CourseSubject
		if err := tx.First(&subject, *input.CourseSubjectID).Error; err == nil {
			return &subject, candidates, nil
		}
		// 客户端提交的 ID 不可信时回退到名称解析，不直接报错。
	}
	switch {
	case len(candidates) == 1 && candidates[0].Match == string(models.CourseSubjectMatchExact):
		var subject models.CourseSubject
		if err := tx.First(&subject, candidates[0].ID).Error; err != nil {
			return nil, nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取学科失败", err)
		}
		return &subject, candidates, nil
	case len(candidates) == 0:
		return nil, nil, nil
	default:
		return nil, candidates, nil
	}
}

// selectTeacher 确定教师。客户端提交的 teacher_id 必须属于该学科且已审核，否则忽略。
func (s *CourseEvaluationService) selectTeacher(tx *gorm.DB, subject *models.CourseSubject, input SubmitInput) (*models.Teacher, error) {
	if input.TeacherID != nil && *input.TeacherID != 0 {
		var teacher models.Teacher
		err := tx.Where("id = ? AND course_subject_id = ? AND verified = ?", *input.TeacherID, subject.ID, true).
			First(&teacher).Error
		if err == nil {
			return &teacher, nil
		}
		// ID 不属于该学科或未审核：不信任，继续按名称解析。
	}
	teachers, err := s.resolveTeachersTx(tx, subject.ID, input.TeacherName)
	if err != nil {
		return nil, err
	}
	for _, t := range teachers {
		if t.Verified {
			var teacher models.Teacher
			if err := tx.First(&teacher, t.ID).Error; err == nil {
				return &teacher, nil
			}
		}
	}
	if len(teachers) > 0 {
		var teacher models.Teacher
		if err := tx.First(&teacher, teachers[0].ID).Error; err == nil {
			return &teacher, nil
		}
	}
	return nil, nil
}

// upsertTeacherRating 维护"一位用户对一位教师一条"的唯一约束。
func upsertTeacherRating(tx *gorm.DB, userID, teacherID uint, submission *models.CourseEvaluationSubmission) (*models.TeacherRating, error) {
	var rating models.TeacherRating
	err := tx.Where("teacher_id = ? AND user_id = ?", teacherID, userID).First(&rating).Error
	switch {
	case err == nil:
		rating.Star = submission.Star
		rating.Comment = submission.Comment
		rating.Status = "normal"
		rating.CourseEvaluationSubmissionID = &submission.ID
		if err := tx.Save(&rating).Error; err != nil {
			return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "更新教师评价失败", err)
		}
		return &rating, nil
	case errors.Is(err, gorm.ErrRecordNotFound):
		rating = models.TeacherRating{
			TeacherID:                    teacherID,
			UserID:                       userID,
			Star:                         submission.Star,
			Comment:                      submission.Comment,
			Status:                       "normal",
			CourseEvaluationSubmissionID: &submission.ID,
		}
		if err := tx.Create(&rating).Error; err != nil {
			return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "创建教师评价失败", err)
		}
		return &rating, nil
	default:
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取教师评价失败", err)
	}
}

// ListMine 分页读取当前用户的提交记录。
func (s *CourseEvaluationService) ListMine(userID uint, limit int, cursor string) (*SubmissionPage, error) {
	if s == nil || s.db == nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "评价服务不可用", nil)
	}
	if userID == 0 {
		return nil, courseEvalErr(CodeCourseEvaluationForbidden, "请先登录", nil)
	}
	query := s.db.Model(&models.CourseEvaluationSubmission{}).Where("user_id = ?", userID)
	return s.paginate(query, limit, cursor)
}

// ListPending 分页读取待审核的提交记录。
func (s *CourseEvaluationService) ListPending(limit int, cursor string) (*SubmissionPage, error) {
	if s == nil || s.db == nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "评价服务不可用", nil)
	}
	query := s.db.Model(&models.CourseEvaluationSubmission{}).
		Where("status = ?", models.CourseEvaluationStatusPending)
	return s.paginate(query, limit, cursor)
}

func (s *CourseEvaluationService) paginate(query *gorm.DB, limit int, cursor string) (*SubmissionPage, error) {
	if limit <= 0 {
		limit = courseEvaluationDefaultPageSize
	}
	if limit > courseEvaluationMaxPageSize {
		limit = courseEvaluationMaxPageSize
	}
	if cursor != "" {
		var cursorID uint
		if _, err := fmt.Sscanf(cursor, "%d", &cursorID); err != nil || cursorID == 0 {
			return nil, courseEvalErr(CodeInvalidCourseEvaluationInput, "无效的分页游标", nil)
		}
		query = query.Where("id < ?", cursorID)
	}

	var rows []models.CourseEvaluationSubmission
	if err := query.Order("id DESC").Limit(limit + 1).Find(&rows).Error; err != nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取评价列表失败", err)
	}
	hasMore := len(rows) > limit
	if hasMore {
		rows = rows[:limit]
	}
	page := &SubmissionPage{Items: []SubmissionView{}, HasMore: hasMore}
	for i := range rows {
		view, err := s.toSubmissionView(&rows[i])
		if err != nil {
			return nil, err
		}
		page.Items = append(page.Items, *view)
	}
	if hasMore && len(rows) > 0 {
		page.NextCursor = fmt.Sprintf("%d", rows[len(rows)-1].ID)
	}
	return page, nil
}

func (s *CourseEvaluationService) findSubmissionByDedupTx(tx *gorm.DB, userID uint, courseName, teacherName string) (*models.CourseEvaluationSubmission, error) {
	key := models.CourseEvaluationDedupKey(userID, courseName, teacherName)
	var submission models.CourseEvaluationSubmission
	err := tx.Where("user_id = ? AND dedup_key = ?", userID, key).First(&submission).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取提交记录失败", err)
	}
	return &submission, nil
}

func (s *CourseEvaluationService) resolveSubjectsTx(tx *gorm.DB, courseName string) ([]CourseSubjectCandidate, error) {
	svc := &CourseEvaluationService{db: tx}
	return svc.resolveSubjects(courseName)
}

func (s *CourseEvaluationService) resolveTeachersTx(tx *gorm.DB, subjectID uint, teacherName string) ([]TeacherCandidate, error) {
	svc := &CourseEvaluationService{db: tx}
	return svc.resolveTeachers(subjectID, teacherName)
}

func (s *CourseEvaluationService) toSubmissionView(sub *models.CourseEvaluationSubmission) (*SubmissionView, error) {
	view := &SubmissionView{
		ID:                  sub.ID,
		UserID:              sub.UserID,
		CourseName:          sub.CourseName,
		CourseSubjectID:     sub.CourseSubjectID,
		CourseSubjectName:   sub.CourseSubjectName,
		TeacherName:         sub.TeacherName,
		TeacherID:           sub.TeacherID,
		Star:                sub.Star,
		Comment:             sub.Comment,
		Status:              sub.Status,
		Source:              sub.Source,
		Revision:            sub.Revision,
		ReviewReason:        sub.ReviewReason,
		TeacherRatingID:     sub.TeacherRatingID,
		ProposedCourseName:  sub.ProposedCourseName,
		ProposedTeacherName: sub.ProposedTeacherName,
		CreatedAt:           sub.CreatedAt,
		UpdatedAt:           sub.UpdatedAt,
	}
	if sub.CourseSubjectID == nil || *sub.CourseSubjectID == 0 {
		view.WillCreateSubject = true
	} else if sub.CourseSubjectName == "" {
		var subject models.CourseSubject
		if err := s.db.Select("id", "name").First(&subject, *sub.CourseSubjectID).Error; err == nil {
			view.CourseSubjectName = subject.Name
		}
	}
	if sub.ReviewedBy != nil && *sub.ReviewedBy != 0 {
		var admin models.User
		if err := s.db.Select("id", "nickname").First(&admin, *sub.ReviewedBy).Error; err == nil {
			view.ReviewerName = admin.Nickname
		}
	}
	return view, nil
}

// escapeLike 转义 LIKE 通配符，避免课程名中的 % 或 _ 变成通配符。
func escapeLike(s string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s)
}

// lockSubmissionForReview 在事务内锁定提交记录，避免并发审批互相覆盖。
func lockSubmissionForReview(tx *gorm.DB, submissionID uint) (*models.CourseEvaluationSubmission, error) {
	var submission models.CourseEvaluationSubmission
	err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
		Where("id = ?", submissionID).First(&submission).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, courseEvalErr(CodeCourseEvaluationNotFound, "评价记录不存在", nil)
	}
	if err != nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "锁定评价记录失败", err)
	}
	return &submission, nil
}
