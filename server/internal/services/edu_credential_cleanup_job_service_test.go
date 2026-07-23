package services

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type eduCredentialCleanupRemoteStub struct {
	errors           []error
	userIDs          []uint
	deleteIdentities []bool
}

func (s *eduCredentialCleanupRemoteStub) Unbind(_ context.Context, userID uint, _ uint, deleteIdentity bool) error {
	s.userIDs = append(s.userIDs, userID)
	s.deleteIdentities = append(s.deleteIdentities, deleteIdentity)
	if len(s.errors) == 0 {
		return nil
	}
	err := s.errors[0]
	s.errors = s.errors[1:]
	return err
}

func TestEduCredentialCleanupJobServiceRetriesUntilRemoteUnbindSucceeds(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.EduCredentialCleanupJob{}); err != nil {
		t.Fatalf("migrate cleanup jobs: %v", err)
	}

	now := time.Date(2026, 7, 18, 8, 0, 0, 0, time.UTC)
	user := models.User{ID: 42, StudentID: "2026000042", PasswordHash: "x", EduSessionState: "revoked", EduAuthorizationGeneration: 1, EduCleanupPending: true}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	remote := &eduCredentialCleanupRemoteStub{errors: []error{errors.New("教务服务暂不可用"), nil}}
	service := NewEduCredentialCleanupJobService(db, remote, func() time.Time { return now })
	if err := db.Transaction(func(tx *gorm.DB) error {
		return service.Enqueue(tx, 42, 1, now, false)
	}); err != nil {
		t.Fatalf("enqueue cleanup job: %v", err)
	}

	firstReport, err := service.ProcessDue(context.Background(), 10)
	if err != nil {
		t.Fatalf("process first attempt: %v", err)
	}
	if firstReport.Processed != 1 || firstReport.Failed != 1 || firstReport.Completed != 0 {
		t.Fatalf("unexpected first report: %#v", firstReport)
	}
	var failed models.EduCredentialCleanupJob
	if err := db.Where("user_id = ?", 42).First(&failed).Error; err != nil {
		t.Fatalf("load failed job: %v", err)
	}
	if failed.CompletedAt != nil || failed.Attempts != 1 || failed.LastError == "" || !failed.NextAttemptAt.After(now) {
		t.Fatalf("failed job state is invalid: %#v", failed)
	}

	now = failed.NextAttemptAt
	secondReport, err := service.ProcessDue(context.Background(), 10)
	if err != nil {
		t.Fatalf("process retry: %v", err)
	}
	if secondReport.Processed != 1 || secondReport.Completed != 1 || secondReport.Failed != 0 {
		t.Fatalf("unexpected retry report: %#v", secondReport)
	}
	var completed models.EduCredentialCleanupJob
	if err := db.Where("user_id = ?", 42).First(&completed).Error; err != nil {
		t.Fatalf("load completed job: %v", err)
	}
	if completed.CompletedAt == nil || completed.LastError != "" {
		t.Fatalf("completed job state is invalid: %#v", completed)
	}
	if len(remote.userIDs) != 2 || remote.userIDs[0] != 42 || remote.userIDs[1] != 42 {
		t.Fatalf("remote calls=%v, want two calls for user 42", remote.userIDs)
	}
}

func TestEduCredentialCleanupJobServiceSkipsStaleGenerationAfterRebind(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.EduCredentialCleanupJob{}); err != nil {
		t.Fatalf("migrate cleanup jobs: %v", err)
	}
	now := time.Date(2026, 7, 22, 8, 0, 0, 0, time.UTC)
	user := models.User{ID: 43, StudentID: "2026000043", PasswordHash: "x", EduSessionState: "revoked", EduAuthorizationGeneration: 1, EduCleanupPending: true}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	remote := &eduCredentialCleanupRemoteStub{}
	service := NewEduCredentialCleanupJobService(db, remote, func() time.Time { return now })
	if err := db.Transaction(func(tx *gorm.DB) error {
		return service.Enqueue(tx, user.ID, 1, now, false)
	}); err != nil {
		t.Fatalf("enqueue cleanup job: %v", err)
	}
	if err := db.Model(&models.User{}).Where("id = ?", user.ID).Updates(map[string]interface{}{
		"edu_authorized":               true,
		"edu_bound":                    true,
		"edu_session_state":            "active",
		"edu_authorization_generation": 2,
		"edu_cleanup_pending":          false,
	}).Error; err != nil {
		t.Fatalf("simulate rebind: %v", err)
	}
	report, err := service.ProcessDue(context.Background(), 10)
	if err != nil {
		t.Fatalf("process stale job: %v", err)
	}
	if report.Processed != 1 || report.Completed != 1 || len(remote.userIDs) != 0 {
		t.Fatalf("stale job should complete without remote deletion: report=%#v calls=%v", report, remote.userIDs)
	}
}

func TestEduCredentialCleanupJobServiceUpgradesPendingRevokeToIdentityDeletion(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.EduCredentialCleanupJob{}); err != nil {
		t.Fatalf("migrate cleanup jobs: %v", err)
	}
	now := time.Date(2026, 7, 23, 9, 0, 0, 0, time.UTC)
	user := models.User{
		ID: 44, StudentID: "2026000044", PasswordHash: "x", AccountStatus: "active",
		EduSessionState: "revoked", EduAuthorizationGeneration: 3, EduCleanupPending: true,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	remote := &eduCredentialCleanupRemoteStub{}
	service := NewEduCredentialCleanupJobService(db, remote, func() time.Time { return now })
	if err := db.Transaction(func(tx *gorm.DB) error {
		return service.Enqueue(tx, user.ID, 3, now, false)
	}); err != nil {
		t.Fatalf("enqueue ordinary revoke: %v", err)
	}
	if err := db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.User{}).Where("id = ?", user.ID).Updates(map[string]interface{}{
			"account_status": "cancelled", "edu_cleanup_pending": true,
		}).Error; err != nil {
			return err
		}
		return service.Enqueue(tx, user.ID, 3, now, true)
	}); err != nil {
		t.Fatalf("upgrade cleanup job for cancellation: %v", err)
	}

	var jobs []models.EduCredentialCleanupJob
	if err := db.Where("user_id = ? AND completed_at IS NULL", user.ID).Find(&jobs).Error; err != nil {
		t.Fatalf("load pending cleanup jobs: %v", err)
	}
	if len(jobs) != 1 || !jobs[0].DeleteIdentity {
		t.Fatalf("cleanup job was not upgraded: %#v", jobs)
	}
	report, err := service.ProcessDue(context.Background(), 10)
	if err != nil {
		t.Fatalf("process upgraded cleanup job: %v", err)
	}
	if report.Completed != 1 || len(remote.deleteIdentities) != 1 || !remote.deleteIdentities[0] {
		t.Fatalf("identity deletion was skipped: report=%#v calls=%v", report, remote.deleteIdentities)
	}
}

func TestEduCredentialCleanupJobServiceRemovesRegistrationCleanupPlaceholder(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.EduCredentialCleanupJob{},
		&models.UserLegalConsent{},
		&models.EmailVerificationChallenge{},
	); err != nil {
		t.Fatalf("migrate cleanup tables: %v", err)
	}
	now := time.Date(2026, 7, 23, 10, 0, 0, 0, time.UTC)
	user := models.User{
		ID:                         45,
		StudentID:                  "2026000045",
		PasswordHash:               "x",
		AccountStatus:              "registration_cleanup_pending",
		EduSessionState:            "revoked",
		EduAuthorizationGeneration: 1,
		EduCleanupPending:          true,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create placeholder user: %v", err)
	}
	if err := db.Create(&models.UserLegalConsent{UserID: user.ID, Document: "privacy", Version: "v1", Scene: "registration"}).Error; err != nil {
		t.Fatalf("create placeholder consent: %v", err)
	}
	userID := user.ID
	if err := db.Create(&models.EmailVerificationChallenge{UserID: &userID, Email: "pending@example.com", Purpose: "register", CodeHash: "hash", RequestIPHash: "ip", ExpiresAt: now.Add(time.Hour)}).Error; err != nil {
		t.Fatalf("create placeholder email challenge: %v", err)
	}
	remote := &eduCredentialCleanupRemoteStub{}
	service := NewEduCredentialCleanupJobService(db, remote, func() time.Time { return now })
	if err := db.Transaction(func(tx *gorm.DB) error {
		return service.Enqueue(tx, user.ID, 1, now, true)
	}); err != nil {
		t.Fatalf("enqueue identity deletion: %v", err)
	}

	report, err := service.ProcessDue(context.Background(), 10)
	if err != nil {
		t.Fatalf("process identity deletion: %v", err)
	}
	if report.Completed != 1 || len(remote.deleteIdentities) != 1 || !remote.deleteIdentities[0] {
		t.Fatalf("identity deletion did not complete: report=%#v calls=%v", report, remote.deleteIdentities)
	}
	var users, consents, challenges int64
	if err := db.Model(&models.User{}).Where("id = ?", user.ID).Count(&users).Error; err != nil {
		t.Fatalf("count placeholder user: %v", err)
	}
	if err := db.Model(&models.UserLegalConsent{}).Where("user_id = ?", user.ID).Count(&consents).Error; err != nil {
		t.Fatalf("count placeholder consent: %v", err)
	}
	if err := db.Model(&models.EmailVerificationChallenge{}).Where("user_id = ?", user.ID).Count(&challenges).Error; err != nil {
		t.Fatalf("count placeholder email challenge: %v", err)
	}
	if users != 0 || consents != 0 || challenges != 0 {
		t.Fatalf("registration cleanup placeholder remained: users=%d consents=%d challenges=%d", users, consents, challenges)
	}
}
