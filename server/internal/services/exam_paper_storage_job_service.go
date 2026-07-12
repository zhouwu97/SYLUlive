package services

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

const examPaperStorageJobLease = 5 * time.Minute

// ExamPaperStorageJobRemote 定义 outbox 消费者需要的远端幂等操作。
type ExamPaperStorageJobRemote interface {
	Claim(context.Context, string) error
	Trash(context.Context, string) error
}

// ExamPaperStorageJobProcessReport 汇总一次消费批次的结果；单任务失败记录在 Failed 中，不中止批次。
type ExamPaperStorageJobProcessReport struct {
	Processed int
	Completed int
	Failed    int
}

// ExamPaperStorageJobService 负责在事务内入队，并以数据库租约并发消费远端操作。
type ExamPaperStorageJobService struct {
	db     *gorm.DB
	remote ExamPaperStorageJobRemote
	now    func() time.Time
}

// NewExamPaperStorageJobService 创建远端文件 outbox 服务。
func NewExamPaperStorageJobService(db *gorm.DB, remote ExamPaperStorageJobRemote, now func() time.Time) *ExamPaperStorageJobService {
	if now == nil {
		now = time.Now
	}
	return &ExamPaperStorageJobService{db: db, remote: remote, now: now}
}

// Enqueue 在调用方提供的数据库事务中幂等写入任务。
func (s *ExamPaperStorageJobService) Enqueue(tx *gorm.DB, backend models.ExamPaperStorageBackend, fileKey, operation string) error {
	if tx == nil || backend != models.ExamPaperStorageRemote || !validExamPaperRemoteFileKey(fileKey) ||
		(operation != ExamPaperStoragePurposeClaim && operation != ExamPaperStoragePurposeDelete) {
		return fmt.Errorf("试卷存储任务参数无效")
	}
	if operation == ExamPaperStoragePurposeDelete {
		var references int64
		if err := tx.Model(&models.ExamPaper{}).
			Where("storage_backend = ? AND file_key = ? AND status IN ?", backend, fileKey, []models.ExamPaperStatus{models.ExamPaperStatusPending, models.ExamPaperStatusPublished}).
			Count(&references).Error; err != nil {
			return err
		}
		if references > 0 {
			return nil
		}
	}
	job := models.ExamPaperStorageJob{
		StorageBackend: backend, FileKey: fileKey, Operation: operation, NextAttemptAt: s.now(),
	}
	return tx.Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "storage_backend"}, {Name: "file_key"}, {Name: "operation"}}, DoNothing: true}).Create(&job).Error
}

// EnqueueClaim 在现有事务内加入认领任务。
func (s *ExamPaperStorageJobService) EnqueueClaim(tx *gorm.DB, backend models.ExamPaperStorageBackend, fileKey string) error {
	return s.Enqueue(tx, backend, fileKey, ExamPaperStoragePurposeClaim)
}

// EnqueueTrash 在现有事务内加入回收任务。
func (s *ExamPaperStorageJobService) EnqueueTrash(tx *gorm.DB, backend models.ExamPaperStorageBackend, fileKey string) error {
	return s.Enqueue(tx, backend, fileKey, ExamPaperStoragePurposeDelete)
}

// ProcessDue 领取并处理一批到期任务。远端失败会持久化重试状态，不作为批次级错误返回。
func (s *ExamPaperStorageJobService) ProcessDue(ctx context.Context, limit int) (ExamPaperStorageJobProcessReport, error) {
	if limit <= 0 {
		return ExamPaperStorageJobProcessReport{}, nil
	}
	if err := ctx.Err(); err != nil {
		return ExamPaperStorageJobProcessReport{}, err
	}
	jobs, err := s.claimDue(ctx, limit)
	if err != nil {
		return ExamPaperStorageJobProcessReport{}, err
	}
	report := ExamPaperStorageJobProcessReport{Processed: len(jobs)}
	for _, job := range jobs {
		if err := ctx.Err(); err != nil {
			return report, err
		}
		operationErr := s.execute(ctx, job)
		if operationErr == nil {
			if err := s.complete(ctx, job); err != nil {
				return report, err
			}
			report.Completed++
			continue
		}
		if err := s.fail(ctx, job, operationErr); err != nil {
			return report, err
		}
		report.Failed++
	}
	return report, nil
}

// ProcessJob 立即尝试消费指定任务，供上传完成后的尽力调用使用。
func (s *ExamPaperStorageJobService) ProcessJob(ctx context.Context, jobID uint) error {
	job, claimed, err := s.claimOne(ctx, jobID, true)
	if err != nil || !claimed {
		return err
	}
	operationErr := s.execute(ctx, job)
	if operationErr == nil {
		return s.complete(ctx, job)
	}
	if err := s.fail(ctx, job, operationErr); err != nil {
		return err
	}
	return operationErr
}

func (s *ExamPaperStorageJobService) claimDue(ctx context.Context, limit int) ([]models.ExamPaperStorageJob, error) {
	now := s.now()
	expired := now.Add(-examPaperStorageJobLease)
	var candidates []models.ExamPaperStorageJob
	dueQuery := func(db *gorm.DB) *gorm.DB {
		return db.WithContext(ctx).Where(
			"completed_at IS NULL AND next_attempt_at <= ? AND (locked_at IS NULL OR locked_at <= ?)", now, expired,
		).Order("next_attempt_at ASC, id ASC").Limit(limit)
	}
	if s.db.Dialector.Name() == "postgres" {
		var claimed []models.ExamPaperStorageJob
		err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
			if err := dueQuery(tx).Clauses(clause.Locking{Strength: "UPDATE", Options: "SKIP LOCKED"}).Find(&candidates).Error; err != nil {
				return err
			}
			for _, candidate := range candidates {
				token := uuid.NewString()
				if err := tx.Model(&models.ExamPaperStorageJob{}).Where("id = ?", candidate.ID).Updates(map[string]any{"locked_at": now, "lock_token": token}).Error; err != nil {
					return err
				}
				candidate.LockedAt = &now
				candidate.LockToken = token
				claimed = append(claimed, candidate)
			}
			return nil
		})
		return claimed, err
	}
	if err := dueQuery(s.db).Find(&candidates).Error; err != nil {
		return nil, err
	}
	claimed := make([]models.ExamPaperStorageJob, 0, len(candidates))
	for _, candidate := range candidates {
		job, ok, err := s.claimOne(ctx, candidate.ID, false)
		if err != nil {
			if isStorageJobDatabaseBusy(err) {
				continue
			}
			return nil, err
		}
		if ok {
			claimed = append(claimed, job)
		}
	}
	return claimed, nil
}

func (s *ExamPaperStorageJobService) claimOne(ctx context.Context, jobID uint, ignoreSchedule bool) (models.ExamPaperStorageJob, bool, error) {
	now := s.now()
	expired := now.Add(-examPaperStorageJobLease)
	token := uuid.NewString()
	query := s.db.WithContext(ctx).Model(&models.ExamPaperStorageJob{}).
		Where("id = ? AND completed_at IS NULL AND (locked_at IS NULL OR locked_at <= ?)", jobID, expired)
	if !ignoreSchedule {
		query = query.Where("next_attempt_at <= ?", now)
	}
	result := query.Updates(map[string]any{"locked_at": now, "lock_token": token})
	if result.Error != nil {
		return models.ExamPaperStorageJob{}, false, result.Error
	}
	if result.RowsAffected == 0 {
		return models.ExamPaperStorageJob{}, false, nil
	}
	var job models.ExamPaperStorageJob
	if err := s.db.WithContext(ctx).Where("id = ? AND lock_token = ?", jobID, token).First(&job).Error; err != nil {
		return models.ExamPaperStorageJob{}, false, err
	}
	return job, true, nil
}

func (s *ExamPaperStorageJobService) execute(ctx context.Context, job models.ExamPaperStorageJob) error {
	if s.remote == nil {
		return errors.New("试卷远端存储客户端未配置")
	}
	switch job.Operation {
	case ExamPaperStoragePurposeClaim:
		return s.remote.Claim(ctx, job.FileKey)
	case ExamPaperStoragePurposeDelete:
		return s.remote.Trash(ctx, job.FileKey)
	default:
		return fmt.Errorf("未知试卷存储任务操作: %s", job.Operation)
	}
}

func (s *ExamPaperStorageJobService) complete(ctx context.Context, job models.ExamPaperStorageJob) error {
	now := s.now()
	result := s.db.WithContext(ctx).Model(&models.ExamPaperStorageJob{}).
		Where("id = ? AND lock_token = ? AND completed_at IS NULL", job.ID, job.LockToken).
		Updates(map[string]any{"completed_at": now, "last_error": "", "locked_at": nil, "lock_token": ""})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected != 1 {
		return errors.New("试卷存储任务完成状态已变化")
	}
	return nil
}

func (s *ExamPaperStorageJobService) fail(ctx context.Context, job models.ExamPaperStorageJob, operationErr error) error {
	now := s.now()
	attempts := job.Attempts + 1
	message := operationErr.Error()
	if len(message) > 1000 {
		message = message[:1000]
	}
	result := s.db.WithContext(ctx).Model(&models.ExamPaperStorageJob{}).
		Where("id = ? AND lock_token = ? AND completed_at IS NULL", job.ID, job.LockToken).
		Updates(map[string]any{
			"attempts": attempts, "last_error": message, "next_attempt_at": now.Add(examPaperStorageRetryDelay(attempts)),
			"locked_at": nil, "lock_token": "",
		})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected != 1 {
		return errors.New("试卷存储任务失败状态已变化")
	}
	return nil
}

func examPaperStorageRetryDelay(attempt int) time.Duration {
	delays := []time.Duration{time.Minute, 2 * time.Minute, 5 * time.Minute, 10 * time.Minute}
	if attempt >= 1 && attempt <= len(delays) {
		return delays[attempt-1]
	}
	return time.Hour
}

func isStorageJobDatabaseBusy(err error) bool {
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "database is locked") || strings.Contains(message, "sqlite_busy")
}
