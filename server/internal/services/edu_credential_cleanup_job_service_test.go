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
	errors  []error
	userIDs []uint
}

func (s *eduCredentialCleanupRemoteStub) Unbind(_ context.Context, userID uint) error {
	s.userIDs = append(s.userIDs, userID)
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
	if err := db.AutoMigrate(&models.EduCredentialCleanupJob{}); err != nil {
		t.Fatalf("migrate cleanup jobs: %v", err)
	}

	now := time.Date(2026, 7, 18, 8, 0, 0, 0, time.UTC)
	remote := &eduCredentialCleanupRemoteStub{errors: []error{errors.New("教务服务暂不可用"), nil}}
	service := NewEduCredentialCleanupJobService(db, remote, func() time.Time { return now })
	if err := db.Transaction(func(tx *gorm.DB) error {
		return service.Enqueue(tx, 42)
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
