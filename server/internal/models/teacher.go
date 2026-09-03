package models

import (
	"time"

	"gorm.io/gorm"
)

// Teacher 被评价教师
type Teacher struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	Name      string    `gorm:"size:50;not null;index" json:"name"`
	Course    string    `gorm:"size:100;not null" json:"course"`
	Verified  bool      `gorm:"default:false" json:"verified"`
	CreatedBy uint      `gorm:"index" json:"created_by"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`

	// 标准学科归属。历史数据允许为空，迁移回填后新数据必须归属某个学科。
	CourseSubjectID *uint  `gorm:"index" json:"course_subject_id,omitempty"`
	NameNormalized  string `gorm:"size:50;index" json:"name_normalized"`

	RatingCount int     `gorm:"-" json:"rating_count"`
	AverageStar float64 `gorm:"-" json:"average_star"`
}

// TeacherRating 教师评价
type TeacherRating struct {
	ID        uint           `gorm:"primaryKey" json:"id"`
	TeacherID uint           `gorm:"index;not null" json:"teacher_id"`
	UserID    uint           `gorm:"index;not null" json:"user_id"`
	Star      int            `gorm:"not null" json:"star"`    // 1-5星
	Comment   string         `gorm:"size:500" json:"comment"` // 评价内容
	CreatedAt time.Time      `json:"created_at"`
	UpdatedAt time.Time      `json:"updated_at"`
	DeletedAt gorm.DeletedAt `gorm:"index" json:"-"`

	HelpfulCount   int `gorm:"not null;default:0" json:"helpful_count"`
	UnhelpfulCount int `gorm:"not null;default:0" json:"unhelpful_count"`

	Status           string     `gorm:"size:20;not null;default:normal;index" json:"status"`
	ModeratedBy      *uint      `gorm:"index" json:"moderated_by,omitempty"`
	ModeratedAt      *time.Time `json:"moderated_at,omitempty"`
	ModerationReason string     `gorm:"size:500" json:"-"`

	// 产生该评价的课程评价提交记录。为空表示来自旧教师评价入口。
	CourseEvaluationSubmissionID *uint `gorm:"index" json:"course_evaluation_submission_id,omitempty"`

	// 关联数据（非数据库字段）
	User          *User   `gorm:"foreignKey:UserID" json:"-"`
	UserName      string  `gorm:"-" json:"user_name"`
	UserStudentID string  `gorm:"-" json:"user_student_id"`
	MyVote        *string `gorm:"-" json:"my_vote"`
}
