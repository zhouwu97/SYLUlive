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
	Unbind(context.Context, uint, uint, bool) error
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

// Enqueue 在调用方事务中写入带授权代次的清理任务，使旧任务不会删除后续重新绑定的凭据。
// 同一用户同一代次只保留一个未完成任务；注销等更强的身份删除语义会升级已有普通撤销任务。
func (s *EduCredentialCleanupJobService) Enqueue(tx *gorm.DB, userID uint, expectedGeneration uint, revokedAt time.Time, deleteIdentity bool) error {
	if s == nil || tx == nil || userID == 0 || revokedAt.IsZero() {
		return errors.New("教务凭证清理任务参数无效")
	}
	var existing models.EduCredentialCleanupJob
	err := tx.Where("user_id = ? AND expected_generation = ? AND completed_at IS NULL", userID, expectedGeneration).First(&existing).Error
	if err == nil {
		updates := map[string]interface{}{
			"next_attempt_at": s.now(),
			"revoked_at":      revokedAt,
		}
		if deleteIdentity && !existing.DeleteIdentity {
			updates["delete_identity"] = true
		}
		return tx.Model(&models.EduCredentialCleanupJob{}).Where("id = ? AND completed_at IS NULL", existing.ID).Updates(updates).Error
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return err
	}
	return tx.Create(&models.EduCredentialCleanupJob{
		UserID: userID, ExpectedGeneration: expectedGeneration, RevokedAt: &revokedAt,
		DeleteIdentity: deleteIdentity, NextAttemptAt: s.now(),
	}).Error
}

// CompleteGeneration 在同步删除远端凭据成功后关闭对应 outbox 任务。
// 弱清理不能完成已升级为永久删除身份的任务。
func (s *EduCredentialCleanupJobService) CompleteGeneration(ctx context.Context, userID uint, generation uint, deleteIdentity bool) error {
	if s == nil || s.db == nil {
		return nil
	}
	now := s.now()
	if err := s.db.WithContext(ctx).Model(&models.EduCredentialCleanupJob{}).
		Where("user_id = ? AND expected_generation = ? AND delete_identity = ? AND completed_at IS NULL", userID, generation, deleteIdentity).
		Updates(map[string]interface{}{"completed_at": now, "last_error": "", "locked_at": nil, "lock_token": ""}).Error; err != nil {
		return err
	}
	return s.clearPending(ctx, userID, generation)
}

// CancelOlderGenerations 在用户重新绑定时终止旧代次的待处理任务。
func (s *EduCredentialCleanupJobService) CancelOlderGenerations(tx *gorm.DB, userID uint, generation uint) error {
	if s == nil || tx == nil {
		return nil
	}
	now := s.now()
	return tx.Model(&models.EduCredentialCleanupJob{}).
		Where("user_id = ? AND expected_generation < ? AND completed_at IS NULL", userID, generation).
		Updates(map[string]interface{}{"completed_at": now, "last_error": "已由新的教务授权代次替代", "locked_at": nil, "lock_token": ""}).Error
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
		// 任务被领取后仍可能被注销操作升级为 delete_identity=true；
		// 必须重新读取，以免持有旧副本执行弱清理并错误完成强清理任务。
		var claimed bool
		job, claimed, err = s.reloadClaimedJob(ctx, job.ID, job.LockToken)
		if err != nil {
			return report, err
		}
		if !claimed {
			continue
		}
		applicable, err := s.isStillApplicable(ctx, job)
		if err != nil {
			return report, err
		}
		if !applicable {
			if err := s.complete(ctx, job); err != nil {
				if failErr := s.fail(ctx, job, err); failErr != nil {
					return report, failErr
				}
				report.Failed++
				continue
			}
			report.Completed++
			continue
		}
		if err := s.unbind(ctx, job.UserID, job.ExpectedGeneration, job.DeleteIdentity); err != nil {
			if err := s.fail(ctx, job, err); err != nil {
				return report, err
			}
			report.Failed++
			continue
		}
		if err := s.complete(ctx, job); err != nil {
			if failErr := s.fail(ctx, job, err); failErr != nil {
				return report, failErr
			}
			report.Failed++
			continue
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

func (s *EduCredentialCleanupJobService) unbind(ctx context.Context, userID uint, generation uint, deleteIdentity bool) error {
	if s.remote == nil {
		return errors.New("教务凭证清理客户端未配置")
	}
	return s.remote.Unbind(ctx, userID, generation, deleteIdentity)
}

func (s *EduCredentialCleanupJobService) reloadClaimedJob(ctx context.Context, jobID uint, lockToken string) (models.EduCredentialCleanupJob, bool, error) {
	var job models.EduCredentialCleanupJob
	err := s.db.WithContext(ctx).Where("id = ? AND lock_token = ? AND completed_at IS NULL", jobID, lockToken).First(&job).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return models.EduCredentialCleanupJob{}, false, nil
	}
	if err != nil {
		return models.EduCredentialCleanupJob{}, false, err
	}
	return job, true, nil
}

func (s *EduCredentialCleanupJobService) isStillApplicable(ctx context.Context, job models.EduCredentialCleanupJob) (bool, error) {
	var user models.User
	err := s.db.WithContext(ctx).First(&user, job.UserID).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if user.EduAuthorizationGeneration != job.ExpectedGeneration || user.EduAuthorized {
		return false, nil
	}
	if job.DeleteIdentity {
		return user.EduCleanupPending && (user.AccountStatus == "cancelled" || user.AccountStatus == "registration_cleanup_pending"), nil
	}
	return user.AccountStatus == "active" && user.EduSessionState == "revoked" && user.EduCleanupPending, nil
}

func (s *EduCredentialCleanupJobService) complete(ctx context.Context, job models.EduCredentialCleanupJob) error {
	if job.DeleteIdentity {
		return s.completeIdentityDeletion(ctx, job)
	}
	now := s.now()
	result := s.db.WithContext(ctx).Model(&models.EduCredentialCleanupJob{}).
		Where("id = ? AND lock_token = ? AND delete_identity = ? AND completed_at IS NULL", job.ID, job.LockToken, job.DeleteIdentity).
		Updates(map[string]interface{}{"completed_at": now, "last_error": "", "locked_at": nil, "lock_token": ""})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		// 任务在远端请求完成前升级了清理语义。保留该任务给下一轮强清理，
		// 不能用已完成的弱请求覆盖它；同时立即释放本次租约，避免强清理
		// 还要等待租约超时才开始重试。
		return s.releaseUpgradedJob(ctx, job)
	}
	return s.clearPending(ctx, job.UserID, job.ExpectedGeneration)
}

// completeIdentityDeletion 在同一事务内删除注册占位账号并完成任务。
// 本地删除失败会回滚 completed_at，随后由 fail 释放租约并安排下一次重试。
func (s *EduCredentialCleanupJobService) completeIdentityDeletion(ctx context.Context, job models.EduCredentialCleanupJob) error {
	now := s.now()
	upgraded := false
	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		result := tx.Model(&models.EduCredentialCleanupJob{}).
			Where("id = ? AND lock_token = ? AND delete_identity = ? AND completed_at IS NULL", job.ID, job.LockToken, true).
			Updates(map[string]interface{}{"completed_at": now, "last_error": "", "locked_at": nil, "lock_token": ""})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected == 0 {
			upgraded = true
			return nil
		}
		var user models.User
		err := tx.Where("id = ? AND account_status = ?", job.UserID, "registration_cleanup_pending").First(&user).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil
		}
		if err != nil {
			return err
		}
		if err := tx.Where("user_id = ?", job.UserID).Delete(&models.UserLegalConsent{}).Error; err != nil {
			return err
		}
		if err := tx.Where("user_id = ?", job.UserID).Delete(&models.EmailVerificationChallenge{}).Error; err != nil {
			return err
		}
		return tx.Delete(&models.User{}, job.UserID).Error
	})
	if err != nil {
		return err
	}
	if upgraded {
		return s.releaseUpgradedJob(ctx, job)
	}
	return nil
}

func (s *EduCredentialCleanupJobService) releaseUpgradedJob(ctx context.Context, job models.EduCredentialCleanupJob) error {
	return s.db.WithContext(ctx).Model(&models.EduCredentialCleanupJob{}).
		Where("id = ? AND lock_token = ? AND delete_identity = ? AND completed_at IS NULL", job.ID, job.LockToken, true).
		Updates(map[string]interface{}{"locked_at": nil, "lock_token": "", "next_attempt_at": s.now()}).Error
}

func (s *EduCredentialCleanupJobService) clearPending(ctx context.Context, userID uint, generation uint) error {
	var pending int64
	if err := s.db.WithContext(ctx).Model(&models.EduCredentialCleanupJob{}).
		Where("user_id = ? AND expected_generation = ? AND completed_at IS NULL", userID, generation).
		Count(&pending).Error; err != nil {
		return err
	}
	if pending != 0 {
		return nil
	}
	return s.db.WithContext(ctx).Model(&models.User{}).
		Where("id = ? AND edu_authorization_generation = ? AND edu_authorized = ? AND edu_session_state = ?", userID, generation, false, "revoked").
		Update("edu_cleanup_pending", false).Error
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
