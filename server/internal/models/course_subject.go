package models

import (
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// 课程评价提交状态。
const (
	CourseEvaluationStatusPending   = "pending"
	CourseEvaluationStatusPublished = "published"
	CourseEvaluationStatusNeedsEdit = "needs_edit"
)

// 课程评价来源。目前只允许从正式教务课表发起。
const (
	CourseEvaluationSourceSchedule = "schedule"
)

// 课程名与教师名的长度上限。
const (
	CourseSubjectNameMaxLength      = 100
	TeacherNameMaxLength            = 50
	CourseEvaluationCommentMaxRunes = 200
)

// CourseSubject 标准学科实体。课程评价只依附于标准学科，
// 学科本身不承载评分，评分仍然保存在 teacher_ratings 上。
type CourseSubject struct {
	ID             uint      `gorm:"primaryKey" json:"id"`
	Name           string    `gorm:"size:100;not null" json:"name"`
	NormalizedName string    `gorm:"size:100;not null;index" json:"normalized_name"`
	Verified       bool      `gorm:"not null;default:false;index" json:"verified"`
	CreatedBy      *uint     `gorm:"index" json:"created_by,omitempty"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`

	// 关联数据（非数据库字段）
	TeacherCount int     `gorm:"-" json:"teacher_count"`
	AverageStar  float64 `gorm:"-" json:"average_star"`
	RatingCount  int     `gorm:"-" json:"rating_count"`
}

func (CourseSubject) TableName() string { return "course_subjects" }

// CourseSubjectAlias 标准学科的明确别名。
// 别名只由服务端在审核通过时登记：管理员把"高等数学（上）"归入
// "高等数学A1" 后，后续同名提交可直接命中，不再要求用户手动确认。
// 别名不做模糊合并，因此 A1 与 A2 不会互相污染。
type CourseSubjectAlias struct {
	ID              uint      `gorm:"primaryKey" json:"id"`
	CourseSubjectID uint      `gorm:"not null;index" json:"course_subject_id"`
	Alias           string    `gorm:"size:100;not null" json:"alias"`
	NormalizedAlias string    `gorm:"size:100;not null;uniqueIndex:uq_course_subject_alias" json:"normalized_alias"`
	CreatedAt       time.Time `json:"created_at"`
}

func (CourseSubjectAlias) TableName() string { return "course_subject_aliases" }

// CourseSubjectMatchKind 名称候选的匹配方式。
type CourseSubjectMatchKind string

const (
	CourseSubjectMatchExact    CourseSubjectMatchKind = "exact"
	CourseSubjectMatchAlias    CourseSubjectMatchKind = "alias"
	CourseSubjectMatchContains CourseSubjectMatchKind = "contains"
)

// CourseEvaluationSubmission 一次课程评价提交申请。
// 同一用户在同一学科下通过 dedup_key 保证只有一条进行中的申请。
type CourseEvaluationSubmission struct {
	ID       uint   `gorm:"primaryKey" json:"id"`
	UserID   uint   `gorm:"not null;index" json:"user_id"`
	DedupKey string `gorm:"size:191;not null" json:"-"`
	Source   string `gorm:"size:20;not null;default:schedule" json:"source"`

	// 用户确认的原始输入
	CourseName  string `gorm:"size:100;not null" json:"course_name"`
	TeacherName string `gorm:"size:50;not null" json:"teacher_name"`
	Star        int    `gorm:"not null" json:"star"`
	Comment     string `gorm:"size:1000" json:"comment"`

	// 服务端解析出的标准归属。未审核通过前允许为空。
	CourseSubjectID   *uint  `gorm:"index" json:"course_subject_id,omitempty"`
	CourseSubjectName string `gorm:"size:100" json:"course_subject_name"`
	TeacherID         *uint  `gorm:"index" json:"teacher_id,omitempty"`

	// 待创建实体的用户提议。审核通过后才落库为真实学科/教师。
	ProposedCourseName  string `gorm:"size:100" json:"proposed_course_name"`
	ProposedTeacherName string `gorm:"size:50" json:"proposed_teacher_name"`

	Status string `gorm:"size:20;not null;default:pending;index" json:"status"`

	// 发布后指向的公开教师评价。
	TeacherRatingID *uint `gorm:"index" json:"teacher_rating_id,omitempty"`

	Revision int `gorm:"not null;default:1" json:"revision"`

	ReviewedBy       *uint      `gorm:"index" json:"reviewed_by,omitempty"`
	ReviewedAt       *time.Time `json:"reviewed_at,omitempty"`
	ReviewReason     string     `gorm:"size:1000" json:"review_reason"`
	ReviewAppliedAt  *time.Time `json:"-"`
	ReviewAppliedRev int        `gorm:"not null;default:0" json:"-"`

	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`

	// 关联数据（非数据库字段）
	SubjectName  string `gorm:"-" json:"subject_name,omitempty"`
	TeacherLabel string `gorm:"-" json:"teacher_label,omitempty"`
}

func (CourseEvaluationSubmission) TableName() string { return "course_evaluation_submissions" }

// IsCourseEvaluationStatus 判断状态是否为允许的状态常量。
func IsCourseEvaluationStatus(status string) bool {
	switch status {
	case CourseEvaluationStatusPending, CourseEvaluationStatusPublished, CourseEvaluationStatusNeedsEdit:
		return true
	default:
		return false
	}
}

// CourseEvaluationDedupKey 生成用户维度的去重键。
// 只使用用户确认的课程名与教师名，绝不包含教室、周次、节次等课表私有信息。
func CourseEvaluationDedupKey(userID uint, courseName, teacherName string) string {
	return strings.Join([]string{
		strconv.FormatUint(uint64(userID), 10),
		NormalizeCourseSubjectName(courseName),
		NormalizeTeacherName(teacherName),
	}, "|")
}

// foldFullWidthASCII 把全角 ASCII 区间（！-～）与全角空格折叠为半角。
// 只做等价字符的收敛，不删除括号、后缀或数字，因此
// "高等数学A1" 与 "高等数学A2" 仍然是不同实体。
func foldFullWidthASCII(r rune) rune {
	if r == 0x3000 {
		return ' '
	}
	if r >= 0xFF01 && r <= 0xFF5E {
		return r - 0xFF01 + 0x21
	}
	return r
}

// normalizeNameKey 收敛全角空格、首尾与内部空白以及大小写。
// 不删除括号、后缀或数字，保证"高等数学A1"与"高等数学A2"保持不同实体。
func normalizeNameKey(name string) string {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		return ""
	}
	var builder strings.Builder
	lastSpace := false
	for _, r := range trimmed {
		r = foldFullWidthASCII(r)
		switch {
		case unicode.IsSpace(r):
			lastSpace = builder.Len() > 0
		default:
			if lastSpace && builder.Len() > 0 {
				builder.WriteRune(' ')
			}
			lastSpace = false
			builder.WriteRune(unicode.ToLower(r))
		}
	}
	return builder.String()
}

// NormalizeCourseSubjectName 规范化标准学科名。
// 体育课程按教务课表中的序号归并到同一个“体育”学科，避免体育1-5被拆成多个评价入口；
// 其他课程仍保留原有数字与后缀区分（例如高等数学A1/A2）。
func NormalizeCourseSubjectName(name string) string {
	normalized := normalizeNameKey(name)
	switch normalized {
	case "体育1", "体育2", "体育3", "体育4", "体育5":
		return "体育"
	default:
		return normalized
	}
}

// NormalizeTeacherName 规范化教师名。
func NormalizeTeacherName(name string) string {
	return normalizeNameKey(name)
}

// TruncateCourseEvaluationComment 按 Unicode code point 截断评论，避免按字节切断多字节字符。
func TruncateCourseEvaluationComment(comment string) string {
	if utf8.RuneCountInString(comment) <= CourseEvaluationCommentMaxRunes {
		return comment
	}
	runes := []rune(comment)
	return string(runes[:CourseEvaluationCommentMaxRunes])
}

// CourseEvaluationCommentLength 返回评论的 Unicode code point 数量。
func CourseEvaluationCommentLength(comment string) int {
	return utf8.RuneCountInString(comment)
}
