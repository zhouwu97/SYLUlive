package models

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"gorm.io/gorm"
)

// ExamPaperStatus 表示试卷在投稿审核流程中的状态。
type ExamPaperStatus string

const (
	ExamPaperStatusPending     ExamPaperStatus = "pending"
	ExamPaperStatusPublished   ExamPaperStatus = "published"
	ExamPaperStatusUnpublished ExamPaperStatus = "unpublished"
)

// ExamPaperSource 表示试卷的投稿来源。
type ExamPaperSource string

const (
	ExamPaperSourceUser  ExamPaperSource = "user"
	ExamPaperSourceAdmin ExamPaperSource = "admin"
)

// ExamPaperSemester 表示试卷所属学期。
type ExamPaperSemester string

const (
	ExamPaperSemesterFirst  ExamPaperSemester = "first"
	ExamPaperSemesterSecond ExamPaperSemester = "second"
	ExamPaperSemesterOther  ExamPaperSemester = "other"
)

// ExamPaperType 表示考试类型。
type ExamPaperType string

const (
	ExamPaperTypeMidterm ExamPaperType = "midterm"
	ExamPaperTypeFinal   ExamPaperType = "final"
	ExamPaperTypeMakeup  ExamPaperType = "makeup"
	ExamPaperTypeRetake  ExamPaperType = "retake"
	ExamPaperTypeOther   ExamPaperType = "other"
)

// ExamPaper 保存试卷元数据和私有文件引用。FileKey 只允许在服务端内部使用。
type ExamPaper struct {
	ID              uint                    `gorm:"primaryKey" json:"id"`
	Status          ExamPaperStatus         `gorm:"size:20;not null;index" json:"status"`
	Source          ExamPaperSource         `gorm:"size:20;not null;index" json:"source"`
	SubmitterID     uint                    `gorm:"not null;index" json:"submitter_id"`
	StorageBackend  ExamPaperStorageBackend `gorm:"size:20;not null;default:local;index" json:"-"`
	ReviewerID      *uint                   `gorm:"index" json:"reviewer_id,omitempty"`
	UnpublisherID   *uint                   `gorm:"index" json:"unpublisher_id,omitempty"`
	CourseName      string                  `gorm:"size:100;not null;index" json:"course_name"`
	AcademicYear    string                  `gorm:"size:9;not null;index" json:"academic_year"`
	Semester        ExamPaperSemester       `gorm:"size:20;not null;index" json:"semester"`
	ExamType        ExamPaperType           `gorm:"size:20;not null;index" json:"exam_type"`
	Title           string                  `gorm:"size:300;not null" json:"title"`
	FileKey         string                  `gorm:"size:200" json:"-"`
	FileSize        int64                   `gorm:"not null" json:"file_size"`
	SHA256          string                  `gorm:"size:64;not null;index" json:"-"`
	DownloadCount   int64                   `gorm:"not null;default:0;index" json:"download_count"`
	ApprovalReason  string                  `gorm:"size:500" json:"approval_reason,omitempty"`
	RewardedAt      *time.Time              `json:"rewarded_at,omitempty"`
	RewardRevokedAt *time.Time              `json:"reward_revoked_at,omitempty"`
	PublishedAt     *time.Time              `gorm:"index" json:"published_at,omitempty"`
	UnpublishReason string                  `gorm:"size:500" json:"unpublish_reason,omitempty"`
	UnpublishedAt   *time.Time              `json:"unpublished_at,omitempty"`
	CreatedAt       time.Time               `gorm:"index" json:"created_at"`
	UpdatedAt       time.Time               `json:"updated_at"`

	Submitter   User  `gorm:"foreignKey:SubmitterID" json:"-"`
	Reviewer    *User `gorm:"foreignKey:ReviewerID" json:"-"`
	Unpublisher *User `gorm:"foreignKey:UnpublisherID" json:"-"`
}

// BeforeCreate 保证通过 Go 结构体创建的历史调用默认使用本地存储。
func (p *ExamPaper) BeforeCreate(tx *gorm.DB) error {
	if p.StorageBackend == "" {
		p.StorageBackend = ExamPaperStorageLocal
	}
	return nil
}

// ExamPaperMetadata 是经过服务端规范化后的可信元数据。
type ExamPaperMetadata struct {
	CourseName   string
	AcademicYear string
	Semester     ExamPaperSemester
	ExamType     ExamPaperType
	Title        string
}

var academicYearPattern = regexp.MustCompile(`^(\d{4})-(\d{4})$`)

// NormalizeExamPaperMetadata 校验四项元数据并生成不可由客户端覆盖的标题。
func NormalizeExamPaperMetadata(courseName, academicYear string, semester ExamPaperSemester, examType ExamPaperType) (ExamPaperMetadata, error) {
	courseName = strings.TrimSpace(courseName)
	academicYear = strings.TrimSpace(academicYear)
	if courseName == "" {
		return ExamPaperMetadata{}, fmt.Errorf("课程名不能为空")
	}
	if utf8.RuneCountInString(courseName) > 100 {
		return ExamPaperMetadata{}, fmt.Errorf("课程名不能超过100个字符")
	}

	matches := academicYearPattern.FindStringSubmatch(academicYear)
	if len(matches) != 3 {
		return ExamPaperMetadata{}, fmt.Errorf("学年格式必须为YYYY-YYYY")
	}
	startYear, _ := strconv.Atoi(matches[1])
	endYear, _ := strconv.Atoi(matches[2])
	if endYear != startYear+1 {
		return ExamPaperMetadata{}, fmt.Errorf("学年必须由连续年份组成")
	}

	semesterLabel, ok := map[ExamPaperSemester]string{
		ExamPaperSemesterFirst:  "第一学期",
		ExamPaperSemesterSecond: "第二学期",
		ExamPaperSemesterOther:  "其他",
	}[semester]
	if !ok {
		return ExamPaperMetadata{}, fmt.Errorf("学期值无效")
	}

	typeLabel, ok := map[ExamPaperType]string{
		ExamPaperTypeMidterm: "期中",
		ExamPaperTypeFinal:   "期末",
		ExamPaperTypeMakeup:  "补考",
		ExamPaperTypeRetake:  "重修",
		ExamPaperTypeOther:   "其他",
	}[examType]
	if !ok {
		return ExamPaperMetadata{}, fmt.Errorf("考试类型无效")
	}

	return ExamPaperMetadata{
		CourseName:   courseName,
		AcademicYear: academicYear,
		Semester:     semester,
		ExamType:     examType,
		Title:        fmt.Sprintf("%s · %s · %s · %s", courseName, academicYear, semesterLabel, typeLabel),
	}, nil
}

// EnsureExamPaperIndexes 创建 AutoMigrate 无法表达的 PostgreSQL/SQLite 部分唯一索引。
func EnsureExamPaperIndexes(db *gorm.DB) error {
	statements := []string{
		`CREATE UNIQUE INDEX IF NOT EXISTS uq_exam_papers_active_sha256
ON exam_papers (sha256)
WHERE status IN ('pending', 'published')`,
		`CREATE INDEX IF NOT EXISTS idx_exam_papers_status_published_at
ON exam_papers (status, published_at DESC, id DESC)`,
	}
	for _, statement := range statements {
		if err := db.Exec(statement).Error; err != nil {
			return fmt.Errorf("创建试卷索引失败: %w", err)
		}
	}
	return nil
}
