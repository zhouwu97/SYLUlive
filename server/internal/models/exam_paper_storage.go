package models

import "time"

// ExamPaperStorageBackend 表示试卷文件实际存放的位置。
type ExamPaperStorageBackend string

const (
	ExamPaperStorageLocal  ExamPaperStorageBackend = "local"
	ExamPaperStorageRemote ExamPaperStorageBackend = "remote"
)

// ExamPaperUploadStatus 表示一次远端上传会话的状态。
type ExamPaperUploadStatus string

const (
	ExamPaperUploadOpen      ExamPaperUploadStatus = "open"
	ExamPaperUploadCompleted ExamPaperUploadStatus = "completed"
	ExamPaperUploadExpired   ExamPaperUploadStatus = "expired"
	ExamPaperUploadFailed    ExamPaperUploadStatus = "failed"
)

// ExamPaperUploadSession 保存远端直传过程中的一次性会话信息。
type ExamPaperUploadSession struct {
	ID           string                `gorm:"primaryKey;size:36" json:"id"`
	SubmitterID  uint                  `gorm:"not null;index" json:"submitter_id"`
	CourseName   string                `gorm:"size:100;not null" json:"course_name"`
	AcademicYear string                `gorm:"size:9;not null" json:"academic_year"`
	Semester     ExamPaperSemester     `gorm:"size:20;not null" json:"semester"`
	ExamType     ExamPaperType         `gorm:"size:20;not null" json:"exam_type"`
	Title        string                `gorm:"size:300;not null" json:"title"`
	ExpectedSize int64                 `gorm:"not null" json:"expected_size"`
	Status       ExamPaperUploadStatus `gorm:"size:20;not null;index" json:"status"`
	StorageKey   string                `gorm:"size:200" json:"storage_key"`
	FileSize     int64                 `gorm:"not null;default:0" json:"file_size"`
	SHA256       string                `gorm:"size:64" json:"sha256"`
	ExpiresAt    time.Time             `gorm:"not null;index" json:"expires_at"`
	CompletedAt  *time.Time            `json:"completed_at,omitempty"`
	CreatedAt    time.Time             `gorm:"index" json:"created_at"`
	UpdatedAt    time.Time             `json:"updated_at"`
}

// NewExamPaperUploadSession 创建一个处于 open 状态的远端上传会话。
func NewExamPaperUploadSession(id string, submitterID uint, metadata ExamPaperMetadata, expectedSize int64, expiresAt time.Time) *ExamPaperUploadSession {
	return &ExamPaperUploadSession{
		ID:           id,
		SubmitterID:  submitterID,
		CourseName:   metadata.CourseName,
		AcademicYear: metadata.AcademicYear,
		Semester:     metadata.Semester,
		ExamType:     metadata.ExamType,
		Title:        metadata.Title,
		ExpectedSize: expectedSize,
		Status:       ExamPaperUploadOpen,
		ExpiresAt:    expiresAt,
	}
}

// ExamPaperStorageJob 保存异步文件操作及其重试状态。
type ExamPaperStorageJob struct {
	ID             uint                    `gorm:"primaryKey" json:"id"`
	StorageBackend ExamPaperStorageBackend `gorm:"size:20;not null;index" json:"storage_backend"`
	FileKey        string                  `gorm:"size:200;not null" json:"file_key"`
	Operation      string                  `gorm:"size:30;not null" json:"operation"`
	Attempts       int                     `gorm:"not null;default:0" json:"attempts"`
	NextAttemptAt  *time.Time              `gorm:"index" json:"next_attempt_at,omitempty"`
	CompletedAt    *time.Time              `json:"completed_at,omitempty"`
	LastError      string                  `gorm:"size:1000" json:"last_error,omitempty"`
	CreatedAt      time.Time               `gorm:"index" json:"created_at"`
	UpdatedAt      time.Time               `json:"updated_at"`
}
