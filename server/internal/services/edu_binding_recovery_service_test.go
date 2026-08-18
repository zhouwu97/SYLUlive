package services

import (
	"context"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type eduBindingRecoveryRemoteStub struct {
	status EduBindingRecoveryStatus
	err    error
}

func (s eduBindingRecoveryRemoteStub) Status(_ context.Context, _ uint) (EduBindingRecoveryStatus, error) {
	return s.status, s.err
}

func TestEduBindingRecoveryCompletesEmailAccountAfterRemoteCommit(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}, &models.EduCredentialCleanupJob{}); err != nil {
		t.Fatalf("迁移测试表失败: %v", err)
	}
	now := time.Date(2026, time.July, 23, 9, 0, 0, 0, time.UTC)
	startedAt := now.Add(-eduBindingRecoveryDelay - time.Minute)
	const pendingStudentID = "2026000051"
	user := models.User{
		StudentID: "", Email: "email-user@example.com", PasswordHash: "hash", AccountStatus: "active",
		EduBindingState: "pending", EduBindingPendingGeneration: 1,
		EduBindingPendingStudentID: pendingStudentID, EduBindingStartedAt: &startedAt,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("创建待恢复注册用户失败: %v", err)
	}
	cleanupJobs := NewEduCredentialCleanupJobService(db, nil, func() time.Time { return now })
	service := NewEduBindingRecoveryService(db, eduBindingRecoveryRemoteStub{status: EduBindingRecoveryStatus{
		Authorized: true, CredentialGeneration: 1, StudentID: pendingStudentID,
		Grade: "2026", College: "计算机学院", Major: "软件工程",
	}}, cleanupJobs, func() time.Time { return now })

	report, err := service.ProcessDue(context.Background(), 10)
	if err != nil {
		t.Fatalf("执行绑定恢复失败: %v", err)
	}
	if report.Processed != 1 || report.Completed != 1 || report.Failed != 0 {
		t.Fatalf("恢复报告错误: %#v", report)
	}
	var stored models.User
	if err := db.First(&stored, user.ID).Error; err != nil {
		t.Fatalf("读取恢复后的用户失败: %v", err)
	}
	if stored.StudentID != pendingStudentID || stored.AccountStatus != "active" || stored.EduBindingState != "active" || !stored.EduAuthorized || stored.EduAuthorizationGeneration != 1 || stored.StudentVerifiedAt == nil || stored.EduBindingPendingStudentID != "" {
		t.Fatalf("恢复后的账号状态错误: %#v", stored)
	}
	// 后台恢复没有客户端响应可以下发新 JWT，绝不能悄悄推进 token_version，
	// 否则客户端仍持有的旧 JWT 会在下一次请求被 token_version_expired 拒绝。
	if stored.TokenVersion != user.TokenVersion {
		t.Fatalf("恢复不得修改令牌版本: got=%d want=%d", stored.TokenVersion, user.TokenVersion)
	}
	var consent models.UserLegalConsent
	if err := db.Where("user_id = ? AND document = ?", user.ID, models.LegalDocumentEduDataConsent).First(&consent).Error; err != nil {
		t.Fatalf("读取恢复的专项同意失败: %v", err)
	}
	if consent.RevokedAt != nil {
		t.Fatalf("恢复后的专项同意仍被撤销: %#v", consent)
	}
}

func TestEduBindingRecoverySchedulesIdentityCleanupWhenRemoteHasNoBinding(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.EduCredentialCleanupJob{}); err != nil {
		t.Fatalf("迁移测试表失败: %v", err)
	}
	now := time.Date(2026, time.July, 23, 9, 0, 0, 0, time.UTC)
	startedAt := now.Add(-eduBindingRecoveryDelay - time.Minute)
	user := models.User{
		StudentID: "2026000052", PasswordHash: "hash", AccountStatus: "registration_pending",
		EduBindingState: "pending", EduBindingPendingGeneration: 1,
		EduBindingPendingStudentID: "2026000052", EduBindingStartedAt: &startedAt,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("创建待清理注册用户失败: %v", err)
	}
	cleanupJobs := NewEduCredentialCleanupJobService(db, nil, func() time.Time { return now })
	service := NewEduBindingRecoveryService(db, eduBindingRecoveryRemoteStub{}, cleanupJobs, func() time.Time { return now })

	report, err := service.ProcessDue(context.Background(), 10)
	if err != nil {
		t.Fatalf("执行绑定恢复清理失败: %v", err)
	}
	if report.Processed != 1 || report.Cleaned != 1 || report.Failed != 0 {
		t.Fatalf("清理报告错误: %#v", report)
	}
	var stored models.User
	if err := db.First(&stored, user.ID).Error; err != nil {
		t.Fatalf("读取待清理用户失败: %v", err)
	}
	if stored.AccountStatus != "registration_cleanup_pending" || stored.EduBindingState != "cleanup_pending" || !stored.EduCleanupPending {
		t.Fatalf("待清理账号状态错误: %#v", stored)
	}
	var job models.EduCredentialCleanupJob
	if err := db.Where("user_id = ? AND completed_at IS NULL", user.ID).First(&job).Error; err != nil {
		t.Fatalf("未创建身份清理任务: %v", err)
	}
	if !job.DeleteIdentity || job.ExpectedGeneration != 1 {
		t.Fatalf("身份清理任务语义错误: %#v", job)
	}
}
