package models

import (
	"time"

	"gorm.io/gorm"
)

// 教师与标准学科的来源。
// Verified 只表达"审核过"，不表达名称出处；出处由 CanonicalSource 表达。
const (
	TeacherSourceEduSchedule = "edu_schedule"
	TeacherSourceAdmin       = "admin"
	TeacherSourceLegacy      = "legacy"
	TeacherSourceUser        = "user"
)

// IsTeacherCanonicalSource 判断来源值是否合法。
func IsTeacherCanonicalSource(source string) bool {
	switch source {
	case TeacherSourceEduSchedule, TeacherSourceAdmin, TeacherSourceLegacy, TeacherSourceUser:
		return true
	default:
		return false
	}
}

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

	// 名称出处。edu_schedule=教务课表、admin=管理员确认、legacy=历史数据、user=用户录入。
	CanonicalSource string `gorm:"size:20;not null;default:legacy;index" json:"canonical_source"`

	// 合并标记。非空表示该教师已并入目标教师，列表与统计必须过滤；
	// 保留行本身以维持旧 ID 可跳转与合并历史可追溯。
	MergedIntoID *uint `gorm:"index" json:"merged_into_id,omitempty"`

	RatingCount int     `gorm:"-" json:"rating_count"`
	AverageStar float64 `gorm:"-" json:"average_star"`
}

// ScopeActiveTeachers 统一的活动教师查询范围（排除 merged 实体）。
func ScopeActiveTeachers(db *gorm.DB) *gorm.DB {
	return db.Where("merged_into_id IS NULL")
}

// TeacherAlias 教师别名，受课程约束：同名教师可能真实存在多位，
// 别名只能在"标准学科 + 规范化别名"范围内唯一，禁止全校唯一映射。
// 合并教师时把 loser 原名登记为别名，后续同名输入直接命中 keeper。
type TeacherAlias struct {
	ID              uint      `gorm:"primaryKey" json:"id"`
	TeacherID       uint      `gorm:"not null;index" json:"teacher_id"`
	CourseSubjectID uint      `gorm:"not null;uniqueIndex:uq_teacher_alias" json:"course_subject_id"`
	Alias           string    `gorm:"size:50;not null" json:"alias"`
	NormalizedAlias string    `gorm:"size:50;not null;uniqueIndex:uq_teacher_alias" json:"normalized_alias"`
	Source          string    `gorm:"size:20;not null;default:admin" json:"source"`
	CreatedBy       *uint     `gorm:"index" json:"created_by,omitempty"`
	CreatedAt       time.Time `json:"created_at"`
}

func (TeacherAlias) TableName() string { return "teacher_aliases" }

// TeacherMergeRecord 一次教师合并的审计快照。
// 采用按 loser 分解存储：同一个合并 BatchID 对应多个 loser，
// 支持精确追溯每个 loser 的迁移指标与快照。
type TeacherMergeRecord struct {
	ID      uint   `gorm:"primaryKey" json:"id"`
	BatchID string `gorm:"size:40;not null;index" json:"batch_id"`

	KeeperID uint `gorm:"not null;index" json:"keeper_id"`
	LoserID  uint `gorm:"not null;index" json:"loser_id"`

	KeeperNameSnapshot string `gorm:"size:50;not null" json:"keeper_name_snapshot"`
	LoserNameSnapshot  string `gorm:"size:50;not null" json:"loser_name_snapshot"`

	KeeperSubjectNameSnapshot string `gorm:"size:100" json:"keeper_subject_name_snapshot"`
	LoserSubjectNameSnapshot  string `gorm:"size:100" json:"loser_subject_name_snapshot"`

	MigratedRatings    int `gorm:"not null;default:0" json:"migrated_ratings"`
	SoftDeletedRatings int `gorm:"not null;default:0" json:"soft_deleted_ratings"`
	MigratedVotes      int `gorm:"not null;default:0" json:"migrated_votes"`

	MigratedSubmissions   int `gorm:"not null;default:0" json:"migrated_submissions"`
	SupersededSubmissions int `gorm:"not null;default:0" json:"superseded_submissions"`

	CourseAliasesAdded  int `gorm:"not null;default:0" json:"course_aliases_added"`
	TeacherAliasesAdded int `gorm:"not null;default:0" json:"teacher_aliases_added"`

	AdminID   uint   `gorm:"not null;index" json:"admin_id"`
	AdminName string `gorm:"size:100" json:"admin_name"`

	CreatedAt time.Time `json:"created_at"`
}

func (TeacherMergeRecord) TableName() string { return "teacher_merge_records" }

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
