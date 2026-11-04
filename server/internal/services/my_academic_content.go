package services

import (
	"encoding/base64"
	"encoding/json"
	"time"

	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

type MyContentCounts struct {
	Posts       int64 `json:"posts"`
	Market      int64 `json:"market"`
	Evaluations int64 `json:"evaluations"`
	Count       int64 `json:"count"`
}
type AcademicContentPage struct {
	Items                  []SubmissionView `json:"items"`
	NextCursor             string           `json:"next_cursor,omitempty"`
	HasMore                bool             `json:"has_more"`
	Total                  int64            `json:"total"`
	IncludesTeacherRatings bool             `json:"includes_teacher_ratings"`
	ContentCounts          *MyContentCounts `json:"content_counts,omitempty"`
}
type academicContentCursor struct {
	CreatedAt time.Time `json:"at"`
	Kind      string    `json:"kind"`
	ID        uint      `json:"id"`
}

// ListAcademicContent 只从评价主记录读取。兼容参数不再表示拼接两个来源。
func (s *CourseEvaluationService) ListAcademicContent(userID uint, limit int, rawCursor string, includeCounts bool) (*AcademicContentPage, error) {
	if s == nil || s.db == nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "评价服务不可用", nil)
	}
	if userID == 0 {
		return nil, courseEvalErr(CodeCourseEvaluationForbidden, "请先登录", nil)
	}
	// 未完成显式历史迁移时拒绝给出缺项的成功列表；GET 本身不写库。
	var missing int64
	if err := s.db.Model(&models.TeacherRating{}).Where("user_id = ?", userID).
		Where("NOT EXISTS (SELECT 1 FROM course_evaluation_submissions c WHERE c.id = teacher_ratings.course_evaluation_submission_id AND c.teacher_rating_id = teacher_ratings.id AND c.user_id = teacher_ratings.user_id)").Count(&missing).Error; err != nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取评价关联失败", err)
	}
	if missing != 0 {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "历史评价尚未完成统一迁移，请稍后重试", nil)
	}
	if limit <= 0 {
		limit = courseEvaluationDefaultPageSize
	}
	if limit > courseEvaluationMaxPageSize {
		limit = courseEvaluationMaxPageSize
	}
	query := s.db.Model(&models.CourseEvaluationSubmission{}).Where("user_id = ?", userID)
	page := &AcademicContentPage{Items: []SubmissionView{}, IncludesTeacherRatings: true}
	if err := query.Count(&page.Total).Error; err != nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取评价数量失败", err)
	}
	if rawCursor != "" {
		data, err := base64.RawURLEncoding.DecodeString(rawCursor)
		var cursor academicContentCursor
		if err != nil || json.Unmarshal(data, &cursor) != nil || cursor.ID == 0 || cursor.CreatedAt.IsZero() || cursor.Kind != "submission" {
			return nil, courseEvalErr(CodeInvalidCourseEvaluationInput, "无效的分页游标", nil)
		}
		query = query.Where("created_at < ? OR (created_at = ? AND id < ?)", cursor.CreatedAt, cursor.CreatedAt, cursor.ID)
	}
	var rows []models.CourseEvaluationSubmission
	if err := query.Order("created_at DESC, id DESC").Limit(limit + 1).Find(&rows).Error; err != nil {
		return nil, courseEvalErr(CodeCourseEvaluationSubjectUnavailable, "读取评价列表失败", err)
	}
	page.HasMore = len(rows) > limit
	if page.HasMore {
		rows = rows[:limit]
	}
	for i := range rows {
		view, err := s.toSubmissionView(&rows[i])
		if err != nil {
			return nil, err
		}
		page.Items = append(page.Items, *view)
	}
	if page.HasMore {
		last := rows[len(rows)-1]
		data, err := json.Marshal(academicContentCursor{CreatedAt: last.CreatedAt, Kind: "submission", ID: last.ID})
		if err != nil {
			return nil, err
		}
		page.NextCursor = base64.RawURLEncoding.EncodeToString(data)
	}
	if includeCounts {
		counts := &MyContentCounts{Evaluations: page.Total}
		statuses := append(models.PublicPostStatuses(), models.PostStatusModeratedHidden)
		posts := s.db.Model(&models.Post{}).Where("author_id = ? AND status IN ?", userID, statuses)
		if err := posts.Session(&gorm.Session{}).Where("board_id <> ?", models.BoardMarket).Count(&counts.Posts).Error; err != nil {
			return nil, err
		}
		if err := posts.Session(&gorm.Session{}).Where("board_id = ?", models.BoardMarket).Count(&counts.Market).Error; err != nil {
			return nil, err
		}
		counts.Count = counts.Posts + counts.Market + counts.Evaluations
		page.ContentCounts = counts
	}
	return page, nil
}
