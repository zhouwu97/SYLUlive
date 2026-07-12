package services

import (
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

const (
	ExamPaperUploadSessionTTL             = 10 * time.Minute
	ExamPaperMaxPendingSubmissionsPerUser = 5
)

var (
	ErrExamPaperUploadSizeInvalid         = errors.New("exam paper upload size invalid")
	ErrExamPaperUploadSessionNotFound     = errors.New("exam paper upload session not found")
	ErrExamPaperUploadSessionExpired      = errors.New("exam paper upload session expired")
	ErrExamPaperUploadReceiptInvalid      = errors.New("exam paper upload receipt invalid")
	ErrExamPaperUploadDuplicate           = errors.New("exam paper upload duplicate")
	ErrExamPaperUploadSessionInconsistent = errors.New("exam paper upload session inconsistent")
	ErrExamPaperUploadQuotaExceeded       = errors.New("exam paper pending submission quota exceeded")
)

// ExamPaperStorageJobAttempt 在业务事务提交后立即尝试执行一次存储任务。
type ExamPaperStorageJobAttempt func(jobID uint) error

// ExamPaperUploadService 管理远端直传会话及上传回执入库。
type ExamPaperUploadService struct {
	db            *gorm.DB
	grantSigner   *ExamPaperStorageSigner
	receiptSigner *ExamPaperStorageSigner
	now           func() time.Time
	attempt       ExamPaperStorageJobAttempt
}

// NewExamPaperUploadService 创建远端试卷上传服务。
func NewExamPaperUploadService(db *gorm.DB, grantSigner, receiptSigner *ExamPaperStorageSigner, now func() time.Time, attempt ExamPaperStorageJobAttempt) *ExamPaperUploadService {
	if now == nil {
		now = time.Now
	}
	return &ExamPaperUploadService{db: db, grantSigner: grantSigner, receiptSigner: receiptSigner, now: now, attempt: attempt}
}

// CreateSession 保存十分钟有效的上传会话并签发精确路径授权。
func (s *ExamPaperUploadService) CreateSession(user models.User, metadata models.ExamPaperMetadata, expectedSize int64) (*models.ExamPaperUploadSession, string, error) {
	if expectedSize <= 0 || expectedSize > ExamPaperMaxFileSize {
		return nil, "", ErrExamPaperUploadSizeInvalid
	}
	now := s.now()
	session := models.NewExamPaperUploadSession(uuid.NewString(), user.ID, metadata, expectedSize, now.Add(ExamPaperUploadSessionTTL))
	session.CreatedAt = now
	session.UpdatedAt = now
	path := "/v1/uploads/" + session.ID
	token, err := s.grantSigner.SignGrant(ExamPaperStorageGrant{
		Purpose: ExamPaperStoragePurposeUpload, SessionID: session.ID, ExpectedSize: expectedSize, UserID: user.ID,
		Method: http.MethodPost, Path: path, IssuedAt: now.Unix(), ExpiresAt: session.ExpiresAt.Unix(), JTI: uuid.NewString(),
	})
	if err != nil {
		return nil, "", fmt.Errorf("sign exam paper upload grant: %w", err)
	}
	if err := s.db.Create(session).Error; err != nil {
		return nil, "", fmt.Errorf("create exam paper upload session: %w", err)
	}
	return session, token, nil
}

// CompleteSession 将可信上传回执转换为试卷，并在提交后触发一次 claim 尝试。
func (s *ExamPaperUploadService) CompleteSession(userID uint, sessionID, receiptToken string) (*models.ExamPaper, error) {
	var paper models.ExamPaper
	var jobID uint
	shouldAttempt := false
	err := s.db.Transaction(func(tx *gorm.DB) error {
		var user models.User
		userQuery := tx.Where("id = ?", userID)
		if tx.Dialector.Name() == "postgres" {
			userQuery = userQuery.Clauses(clause.Locking{Strength: "UPDATE"})
		}
		if err := userQuery.First(&user).Error; err != nil {
			return err
		}

		var session models.ExamPaperUploadSession
		query := tx.Where("id = ? AND submitter_id = ?", sessionID, userID)
		if tx.Dialector.Name() == "postgres" {
			query = query.Clauses(clause.Locking{Strength: "UPDATE"})
		}
		if err := query.First(&session).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return ErrExamPaperUploadSessionNotFound
			}
			return err
		}
		if session.Status == models.ExamPaperUploadCompleted {
			if session.StorageKey == "" {
				return ErrExamPaperUploadSessionInconsistent
			}
			if err := tx.Preload("Submitter").Where(
				"storage_backend = ? AND file_key = ? AND submitter_id = ? AND file_size = ? AND sha256 = ?",
				models.ExamPaperStorageRemote, session.StorageKey, session.SubmitterID, session.FileSize, session.SHA256,
			).First(&paper).Error; err != nil {
				return ErrExamPaperUploadSessionInconsistent
			}
			return nil
		}
		if session.Status != models.ExamPaperUploadOpen {
			return ErrExamPaperUploadSessionInconsistent
		}
		if !s.now().Before(session.ExpiresAt) {
			return ErrExamPaperUploadSessionExpired
		}
		receipt, err := s.receiptSigner.VerifyReceipt(receiptToken)
		if err != nil || receipt.SessionID != session.ID || receipt.FileSize != session.ExpectedSize ||
			!isExamPaperUploadFileKey(receipt.FileKey) ||
			receipt.IssuedAt < session.CreatedAt.Add(-30*time.Second).Unix() || receipt.IssuedAt > s.now().Add(30*time.Second).Unix() {
			return ErrExamPaperUploadReceiptInvalid
		}

		if user.Role != models.RoleAdmin && user.Role != models.RoleSuperAdmin {
			var pendingCount int64
			if err := tx.Model(&models.ExamPaper{}).
				Where("submitter_id = ? AND status = ?", userID, models.ExamPaperStatusPending).
				Count(&pendingCount).Error; err != nil {
				return err
			}
			if pendingCount >= ExamPaperMaxPendingSubmissionsPerUser {
				return ErrExamPaperUploadQuotaExceeded
			}
		}
		now := s.now()
		paper = models.ExamPaper{
			Status: models.ExamPaperStatusPending, Source: models.ExamPaperSourceUser, SubmitterID: userID,
			StorageBackend: models.ExamPaperStorageRemote, CourseName: session.CourseName,
			AcademicYear: session.AcademicYear, Semester: session.Semester, ExamType: session.ExamType,
			Title: session.Title, FileKey: receipt.FileKey, FileSize: receipt.FileSize, SHA256: receipt.SHA256,
		}
		if user.Role == models.RoleAdmin || user.Role == models.RoleSuperAdmin {
			paper.Status = models.ExamPaperStatusPublished
			paper.Source = models.ExamPaperSourceAdmin
			paper.ReviewerID = &user.ID
			paper.PublishedAt = &now
		}
		if err := tx.Create(&paper).Error; err != nil {
			if isExamPaperUploadDuplicateError(err) {
				return ErrExamPaperUploadDuplicate
			}
			return err
		}
		if err := tx.Model(&session).Updates(map[string]any{
			"storage_key": receipt.FileKey, "file_size": receipt.FileSize, "sha256": receipt.SHA256,
			"status": models.ExamPaperUploadCompleted, "completed_at": now,
		}).Error; err != nil {
			return err
		}
		job := models.ExamPaperStorageJob{
			StorageBackend: models.ExamPaperStorageRemote, FileKey: receipt.FileKey,
			Operation: ExamPaperStoragePurposeClaim, NextAttemptAt: now,
		}
		if err := tx.Create(&job).Error; err != nil {
			return err
		}
		if paper.Source == models.ExamPaperSourceAdmin {
			if err := tx.Create(&models.AdminLog{
				AdminID: user.ID, AdminName: user.Nickname, Action: "直接发布试卷", Target: paper.Title,
				Detail: fmt.Sprintf("试卷ID=%d，管理员远端直传，不发放经验", paper.ID),
			}).Error; err != nil {
				return err
			}
		}
		jobID = job.ID
		shouldAttempt = true
		paper.Submitter = user
		return nil
	})
	if err != nil {
		return nil, err
	}
	if shouldAttempt {
		s.attemptStorageJob(jobID)
	}
	return &paper, nil
}

// attemptStorageJob 在事务提交后尽力触发存储任务；回调异常不得改变已提交的业务结果。
func (s *ExamPaperUploadService) attemptStorageJob(jobID uint) {
	if s.attempt == nil {
		return
	}
	defer func() {
		_ = recover()
	}()
	_ = s.attempt(jobID)
}

func isExamPaperUploadFileKey(fileKey string) bool {
	if !strings.HasSuffix(fileKey, ".pdf") || strings.ContainsAny(fileKey, `/\\`) {
		return false
	}
	_, err := uuid.Parse(strings.TrimSuffix(fileKey, ".pdf"))
	return err == nil
}

func isExamPaperUploadDuplicateError(err error) bool {
	if errors.Is(err, gorm.ErrDuplicatedKey) {
		return true
	}
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "uq_exam_papers_active_sha256") || strings.Contains(message, "unique constraint") || strings.Contains(message, "duplicate key")
}
