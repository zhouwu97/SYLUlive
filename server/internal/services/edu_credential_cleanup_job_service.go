package services

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

const eduCredentialCleanupJobLease = 5 * time.Minute

// EduCredentialCleanupRemote 定义后台任务清理教务服务中凭证副本的操作。
type EduCredentialCleanupRemote interface {
	Unbind(context.Context, uint) error
}

// EduCredentialCleanupJobProcessReport 汇总一批教务凭证清理任务的执行情况。
type EduCredentialCleanupJobProcessReport struct {
	Processed int
	Completed int
	Failed    int
}

// EduCredentialCleanupJobService 通过持久化 outbox 重试远端教务凭证清理。
type EduCredentialCleanupJobService struct {
	db     *gorm.DB
	remote EduCredentialCleanupRemote
	now    func() time.Time
}

// NewEduCredentialCleanupJobService 创建教务凭证清理任务服务。
func NewEduCredentialCleanupJobService(db *gorm.DB, remote EduCredentialCleanupRemote, now func() time.Time) *EduCredentialCleanupJobService {
	if now == nil {
		now = time.Now
	}
	return &EduCredentialCleanupJobService{db: db, remote: remote, now: now}
}

// Enqueue 在调用方事务中写入清理任务，使本地撤销和远端补偿具备原子可见性。
func (s *EduCredentialCleanupJobService) Enqueue(tx *gorm.DB, userID uint) error {
	if tx == nil || userID == 0 {
		return errors.New("教务凭证清理任务参数无效")
	}
	return tx.Create(&models.EduCredentialCleanupJob{UserID: userID, NextAttemptAt: s.now()}).Error
}

// ProcessDue 领取并处理一批到期任务。远端失败只更新重试状态，不会中止后续任务。
func (s *EduCredentialCleanupJobService) ProcessDue(ctx context.Context, limit int) (EduCredentialCleanupJobProcessReport, error) {
	if limit <= 0 {
		return EduCredentialCleanupJobProcessReport{}, nil
	}
	if err := ctx.Err(); err != nil {
		return EduCredentialCleanupJobProcessReport{}, err
	}
	jobs, err := s.claimDue(ctx, limit)
	if err != nil {
		return EduCredentialCleanupJobProcessReport{}, err
	}
	report := EduCredentialCleanupJobProcessReport{Processed: len(jobs)}
	for _, job := range jobs {
		if err := ctx.Err(); err != nil {
			return report, err
		}
		if err := s.unbind(ctx, job.UserID); err != nil {
			if err := s.fail(ctx, job, err); err != nil {
				return report, err
			}
			report.Failed++
			continue
		}
		if err := s.complete(ctx, job); err != nil {
			return report, err
		}
		report.Completed++
	}
	return report, nil
}

func (s *EduCredentialCleanupJobService) claimDue(ctx context.Context, limit int) ([]models.EduCredentialCleanupJob, error) {
	now := s.now()
	expired := now.Add(-eduCredentialCleanupJobLease)
	var candidates []models.EduCredentialCleanupJob
	if err := s.db.WithContext(ctx).
		Where("completed_at IS NULL AND next_attempt_at <= ? AND (locked_at IS NULL OR locked_at <= ?)", now, expired).
		Order("next_attempt_at ASC, id ASC").
		Limit(limit).
		Find(&candidates).Error; err != nil {
		return nil, err
	}
	jobs := make([]models.EduCredentialCleanupJob, 0, len(candidates))
	for _, candidate := range candidates {
		job, claimed, err := s.claimOne(ctx, candidate.ID)
		if err != nil {
			return nil, err
		}
		if claimed {
			jobs = append(jobs, job)
		}
	}
	return jobs, nil
}

func (s *EduCredentialCleanupJobService) claimOne(ctx context.Context, jobID uint) (models.EduCredentialCleanupJob, bool, error) {
	now := s.now()
	token := uuid.NewString()
	expired := now.Add(-eduCredentialCleanupJobLease)
	result := s.db.WithContext(ctx).Model(&models.EduCredentialCleanupJob{}).
		Where("id = ? AND completed_at IS NULL AND next_attempt_at <= ? AND (locked_at IS NULL OR locked_at <= ?)", jobID, now, expired).
		Updates(map[string]interface{}{"locked_at": now, "lock_token": token})
	if result.Error != nil {
		return models.EduCredentialCleanupJob{}, false, result.Error
	}
	if result.RowsAffected == 0 {
		return models.EduCredentialCleanupJob{}, false, nil
	}
	var job models.EduCredentialCleanupJob
	if err := s.db.WithContext(ctx).Where("id = ? AND lock_token = ?", jobID, token).First(&job).Error; err != nil {
		return models.EduCredentialCleanupJob{}, false, err
	}
	return job, true, nil
}

func (s *EduCredentialCleanupJobService) unbind(ctx context.Context, userID uint) error {
	if s.remote == nil {
		return errors.New("教务凭证清理客户端未配置")
	}
	return s.remote.Unbind(ctx, userID)
}

func (s *EduCredentialCleanupJobService) complete(ctx context.Context, job models.EduCredentialCleanupJob) error {
	now := s.now()
	result := s.db.WithContext(ctx).Model(&models.EduCredentialCleanupJob{}).
		Where("id = ? AND lock_token = ? AND completed_at IS NULL", job.ID, job.LockToken).
		Updates(map[string]interface{}{"completed_at": now, "last_error": "", "locked_at": nil, "lock_token": ""})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected != 1 {
		return fmt.Errorf("教务凭证清理任务完成状态已变化: %d", job.ID)
	}
	return nil
}

func (s *EduCredentialCleanupJobService) fail(ctx context.Context, job models.EduCredentialCleanupJob, operationErr error) error {
	now := s.now()
	attempts := job.Attempts + 1
	message := operationErr.Error()
	if len(message) > 1000 {
		message = message[:1000]
	}
	result := s.db.WithContext(ctx).Model(&models.EduCredentialCleanupJob{}).
		Where("id = ? AND lock_token = ? AND completed_at IS NULL", job.ID, job.LockToken).
		Updates(map[string]interface{}{
			"attempts": attempts, "last_error": message, "next_attempt_at": now.Add(eduCredentialCleanupRetryDelay(attempts)),
			"locked_at": nil, "lock_token": "",
		})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected != 1 {
		return fmt.Errorf("教务凭证清理任务失败状态已变化: %d", job.ID)
	}
	return nil
}

func eduCredentialCleanupRetryDelay(attempt int) time.Duration {
	delays := []time.Duration{time.Minute, 2 * time.Minute, 5 * time.Minute, 10 * time.Minute}
	if attempt >= 1 && attempt <= len(delays) {
		return delays[attempt-1]
	}
	return time.Hour
}
