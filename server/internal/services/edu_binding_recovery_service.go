package services

import (
	"context"
	"errors"
	"strings"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

const eduBindingRecoveryDelay = 5 * time.Minute

// EduBindingRecoveryStatus 是 Python 教务服务返回的可用于恢复本地提交的最小身份状态。
type EduBindingRecoveryStatus struct {
	Authorized           bool
	CredentialGeneration uint
	StudentID            string
	Grade                string
	College              string
	Major                string
}

// EduBindingRecoveryRemote 读取远端已持久化的教务绑定状态。
type EduBindingRecoveryRemote interface {
	Status(context.Context, uint) (EduBindingRecoveryStatus, error)
}

// EduBindingRecoveryReport 汇总一批跨服务绑定恢复的执行结果。
type EduBindingRecoveryReport struct {
	Processed int
	Completed int
	Cleaned   int
	Failed    int
}

// EduBindingRecoveryService 处理 Go 在 Python 成功后崩溃留下的 pending 绑定。
type EduBindingRecoveryService struct {
	db          *gorm.DB
	remote      EduBindingRecoveryRemote
	cleanupJobs *EduCredentialCleanupJobService
	now         func() time.Time
}

func NewEduBindingRecoveryService(db *gorm.DB, remote EduBindingRecoveryRemote, cleanupJobs *EduCredentialCleanupJobService, now func() time.Time) *EduBindingRecoveryService {
	if now == nil {
		now = time.Now
	}
	return &EduBindingRecoveryService{db: db, remote: remote, cleanupJobs: cleanupJobs, now: now}
}

// ProcessDue 恢复超过等待窗口的 pending 绑定。远端故障不会清除本地状态，后续周期会继续重试。
func (s *EduBindingRecoveryService) ProcessDue(ctx context.Context, limit int) (EduBindingRecoveryReport, error) {
	if s == nil || s.db == nil || s.remote == nil || limit <= 0 {
		return EduBindingRecoveryReport{}, nil
	}
	if err := ctx.Err(); err != nil {
		return EduBindingRecoveryReport{}, err
	}
	var users []models.User
	if err := s.db.WithContext(ctx).
		Where("edu_binding_state = ? AND edu_binding_pending_generation > edu_authorization_generation AND edu_binding_started_at <= ?", "pending", s.now().Add(-eduBindingRecoveryDelay)).
		Order("edu_binding_started_at ASC, id ASC").
		Limit(limit).
		Find(&users).Error; err != nil {
		return EduBindingRecoveryReport{}, err
	}
	report := EduBindingRecoveryReport{Processed: len(users)}
	for _, user := range users {
		if err := ctx.Err(); err != nil {
			return report, err
		}
		status, err := s.remote.Status(ctx, user.ID)
		if err != nil {
			report.Failed++
			continue
		}
		pendingStudentID := strings.TrimSpace(user.EduBindingPendingStudentID)
		if pendingStudentID == "" {
			// 兼容升级前已持久化的学生账号待绑定记录。
			pendingStudentID = strings.TrimSpace(user.StudentID)
		}
		if status.Authorized && status.CredentialGeneration == user.EduBindingPendingGeneration && status.StudentID == pendingStudentID {
			if err := s.completeBinding(ctx, user.ID, user.EduBindingPendingGeneration, status); err != nil {
				report.Failed++
				continue
			}
			report.Completed++
			continue
		}
		if user.AccountStatus == "registration_pending" {
			if err := s.scheduleRegistrationCleanup(ctx, user.ID, user.EduBindingPendingGeneration); err != nil {
				report.Failed++
				continue
			}
			report.Cleaned++
			continue
		}
		if err := s.releaseBinding(ctx, user.ID, user.EduBindingPendingGeneration); err != nil {
			report.Failed++
			continue
		}
		report.Cleaned++
	}
	return report, nil
}

func (s *EduBindingRecoveryService) completeBinding(ctx context.Context, userID, generation uint, status EduBindingRecoveryStatus) error {
	now := s.now()
	return s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, userID).Error; err != nil {
			return err
		}
		if user.EduBindingState != "pending" || user.EduBindingPendingGeneration != generation {
			return nil
		}
		pendingStudentID := strings.TrimSpace(user.EduBindingPendingStudentID)
		if pendingStudentID == "" {
			pendingStudentID = strings.TrimSpace(user.StudentID)
		}
		if pendingStudentID == "" || pendingStudentID != status.StudentID || status.StudentID == "" {
			return errors.New("远端教务身份与待恢复账号不一致")
		}
		updates := map[string]interface{}{
			"student_id":                     status.StudentID,
			"student_verified_at":            now,
			"edu_student_id":                 status.StudentID,
			"edu_authorized":                 true,
			"edu_session_state":              "active",
			"edu_auto_relogin":               true,
			"edu_authorized_at":              now,
			"edu_session_updated_at":         now,
			"edu_authorization_generation":   generation,
			"edu_cleanup_pending":            false,
			"edu_binding_state":              "active",
			"edu_binding_pending_generation": 0,
			"edu_binding_pending_student_id": "",
			"edu_binding_started_at":         nil,
			"edu_bound":                      true,
			"edu_grade":                      status.Grade,
			"edu_college":                    status.College,
			"edu_major":                      status.Major,
			"edu_password":                   "",
			"edu_cookie":                     "",
		}
		if user.AccountStatus == "registration_pending" {
			updates["account_status"] = "active"
		}
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Updates(updates).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.EduCredentialCleanupJob{}).
			Where("user_id = ? AND expected_generation < ? AND completed_at IS NULL", userID, generation).
			Updates(map[string]interface{}{"completed_at": now, "last_error": "已由恢复的教务授权代次替代", "locked_at": nil, "lock_token": ""}).Error; err != nil {
			return err
		}
		consent := models.UserLegalConsent{
			UserID: userID, Document: models.LegalDocumentEduDataConsent, Version: models.LegalDocumentVersion,
			AcknowledgementType: "separate_consent", Scope: "education", Scene: "edu_binding",
		}
		return tx.Where("user_id = ? AND document = ? AND version = ? AND scene = ?", userID, consent.Document, consent.Version, consent.Scene).
			Assign(map[string]interface{}{"accepted_at": now, "revoked_at": nil, "acknowledgement_type": consent.AcknowledgementType, "scope": consent.Scope}).
			FirstOrCreate(&consent).Error
	})
}

func (s *EduBindingRecoveryService) releaseBinding(ctx context.Context, userID, generation uint) error {
	return s.db.WithContext(ctx).Model(&models.User{}).
		Where("id = ? AND edu_binding_state = ? AND edu_binding_pending_generation = ?", userID, "pending", generation).
		Updates(map[string]interface{}{"edu_binding_state": "idle", "edu_binding_pending_generation": 0, "edu_binding_pending_student_id": "", "edu_binding_started_at": nil}).Error
}

func (s *EduBindingRecoveryService) scheduleRegistrationCleanup(ctx context.Context, userID, generation uint) error {
	if s.cleanupJobs == nil {
		return errors.New("教务凭证清理任务未配置")
	}
	now := s.now()
	return s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		result := tx.Model(&models.User{}).
			Where("id = ? AND account_status = ? AND edu_binding_state = ? AND edu_binding_pending_generation = ?", userID, "registration_pending", "pending", generation).
			Updates(map[string]interface{}{
				"account_status":                 "registration_cleanup_pending",
				"edu_authorization_generation":   generation,
				"edu_authorized":                 false,
				"edu_bound":                      false,
				"edu_session_state":              "revoked",
				"edu_auto_relogin":               false,
				"edu_cleanup_pending":            true,
				"edu_binding_state":              "cleanup_pending",
				"edu_binding_pending_generation": 0,
				"edu_binding_pending_student_id": "",
				"edu_binding_started_at":         nil,
				"edu_session_updated_at":         now,
			})
		if result.Error != nil || result.RowsAffected == 0 {
			if result.Error != nil {
				return result.Error
			}
			// 状态已被并发操作改变，不能将未入队的占位账号误记为已清理。
			return gorm.ErrRecordNotFound
		}
		return s.cleanupJobs.Enqueue(tx, userID, generation, now, true)
	})
}
