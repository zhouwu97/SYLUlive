package services

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type storageJobRemoteStub struct {
	mu       sync.Mutex
	calls    map[string]int
	failures map[string]int
	started  chan string
	release  chan struct{}
}

func (s *storageJobRemoteStub) call(operation, key string) error {
	s.mu.Lock()
	if s.calls == nil {
		s.calls = map[string]int{}
	}
	s.calls[operation+":"+key]++
	remaining := s.failures[operation+":"+key]
	if remaining > 0 {
		s.failures[operation+":"+key] = remaining - 1
	}
	s.mu.Unlock()
	if s.started != nil {
		s.started <- operation + ":" + key
	}
	if s.release != nil {
		<-s.release
	}
	if remaining > 0 {
		return errors.New("远端临时失败")
	}
	return nil
}

func (s *storageJobRemoteStub) Claim(context.Context, string) error { return nil }

func (s *storageJobRemoteStub) Trash(ctx context.Context, key string) error {
	return s.call("trash", key)
}

type dispatchingStorageJobRemoteStub struct{ storageJobRemoteStub }

type postgresNamedDialector struct {
	gorm.Dialector
}

func (postgresNamedDialector) Name() string { return "postgres" }

func (s *dispatchingStorageJobRemoteStub) Claim(ctx context.Context, key string) error {
	return s.call("claim", key)
}

func openStorageJobTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "jobs.db")), &gorm.Config{TranslateError: true})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, sqlDB.Close()) })
	require.NoError(t, db.AutoMigrate(&models.ExamPaper{}, &models.ExamPaperStorageJob{}))
	return db
}

func TestExamPaperStorageJobEnqueueParticipatesInCallerTransaction(t *testing.T) {
	db := openStorageJobTestDB(t)
	service := NewExamPaperStorageJobService(db, &dispatchingStorageJobRemoteStub{}, time.Now)
	errRollback := errors.New("回滚")
	err := db.Transaction(func(tx *gorm.DB) error {
		require.NoError(t, service.Enqueue(tx, models.ExamPaperStorageRemote, "paper.pdf", ExamPaperStoragePurposeDelete))
		return errRollback
	})
	require.ErrorIs(t, err, errRollback)
	var count int64
	require.NoError(t, db.Model(&models.ExamPaperStorageJob{}).Count(&count).Error)
	require.Zero(t, count)
}

func TestExamPaperStorageJobRetriesWithRequiredScheduleAndContinuesBatch(t *testing.T) {
	db := openStorageJobTestDB(t)
	now := time.Date(2026, 7, 12, 10, 0, 0, 0, time.UTC)
	remote := &dispatchingStorageJobRemoteStub{storageJobRemoteStub: storageJobRemoteStub{failures: map[string]int{"trash:bad.pdf": 6}}}
	service := NewExamPaperStorageJobService(db, remote, func() time.Time { return now })
	require.NoError(t, service.Enqueue(db, models.ExamPaperStorageRemote, "bad.pdf", ExamPaperStoragePurposeDelete))
	require.NoError(t, service.Enqueue(db, models.ExamPaperStorageRemote, "good.pdf", ExamPaperStoragePurposeDelete))

	wantDelays := []time.Duration{time.Minute, 2 * time.Minute, 5 * time.Minute, 10 * time.Minute, time.Hour, time.Hour}
	for attempt, delay := range wantDelays {
		report, err := service.ProcessDue(context.Background(), 10)
		require.NoError(t, err)
		if attempt == 0 {
			require.Equal(t, 2, report.Processed)
			require.Equal(t, 1, report.Completed)
		}
		require.Equal(t, 1, report.Failed)
		var job models.ExamPaperStorageJob
		require.NoError(t, db.Where("file_key = ?", "bad.pdf").First(&job).Error)
		require.Equal(t, attempt+1, job.Attempts)
		require.Equal(t, now.Add(delay), job.NextAttemptAt)
		require.NotEmpty(t, job.LastError)
		now = job.NextAttemptAt
	}
}

func TestExamPaperStorageJobDispatchesClaimAndTrashIdempotently(t *testing.T) {
	db := openStorageJobTestDB(t)
	remote := &dispatchingStorageJobRemoteStub{}
	service := NewExamPaperStorageJobService(db, remote, time.Now)
	for index := 0; index < 2; index++ {
		require.NoError(t, service.Enqueue(db, models.ExamPaperStorageRemote, "paper.pdf", ExamPaperStoragePurposeClaim))
		require.NoError(t, service.Enqueue(db, models.ExamPaperStorageRemote, "paper.pdf", ExamPaperStoragePurposeDelete))
	}
	report, err := service.ProcessDue(context.Background(), 10)
	require.NoError(t, err)
	require.Equal(t, 2, report.Completed)
	remote.mu.Lock()
	defer remote.mu.Unlock()
	require.Equal(t, 1, remote.calls["claim:paper.pdf"])
	require.Equal(t, 1, remote.calls["trash:paper.pdf"])
}

func TestExamPaperStorageJobConcurrentConsumersDoNotDoubleProcess(t *testing.T) {
	db := openStorageJobTestDB(t)
	remote := &dispatchingStorageJobRemoteStub{storageJobRemoteStub: storageJobRemoteStub{started: make(chan string, 2), release: make(chan struct{})}}
	service := NewExamPaperStorageJobService(db, remote, time.Now)
	require.NoError(t, service.Enqueue(db, models.ExamPaperStorageRemote, "paper.pdf", ExamPaperStoragePurposeDelete))

	done := make(chan error, 2)
	go func() { _, err := service.ProcessDue(context.Background(), 1); done <- err }()
	<-remote.started
	go func() { _, err := service.ProcessDue(context.Background(), 1); done <- err }()
	time.Sleep(100 * time.Millisecond)
	close(remote.release)
	require.NoError(t, <-done)
	require.NoError(t, <-done)
	remote.mu.Lock()
	defer remote.mu.Unlock()
	require.Equal(t, 1, remote.calls["trash:paper.pdf"])
}

func TestExamPaperStorageJobPostgresClaimHonorsDueFilters(t *testing.T) {
	db := openStorageJobTestDB(t)
	db.Dialector = postgresNamedDialector{Dialector: db.Dialector}
	now := time.Date(2026, 7, 12, 10, 0, 0, 0, time.UTC)
	completedAt := now.Add(-time.Minute)
	jobs := []models.ExamPaperStorageJob{
		{StorageBackend: models.ExamPaperStorageRemote, FileKey: "due.pdf", Operation: ExamPaperStoragePurposeDelete, NextAttemptAt: now},
		{StorageBackend: models.ExamPaperStorageRemote, FileKey: "future.pdf", Operation: ExamPaperStoragePurposeDelete, NextAttemptAt: now.Add(time.Hour)},
		{StorageBackend: models.ExamPaperStorageRemote, FileKey: "completed.pdf", Operation: ExamPaperStoragePurposeDelete, NextAttemptAt: now, CompletedAt: &completedAt},
	}
	require.NoError(t, db.Create(&jobs).Error)
	remote := &dispatchingStorageJobRemoteStub{}
	service := NewExamPaperStorageJobService(db, remote, func() time.Time { return now })

	report, err := service.ProcessDue(context.Background(), 10)
	require.NoError(t, err)
	require.Equal(t, 1, report.Processed)
	remote.mu.Lock()
	defer remote.mu.Unlock()
	require.Equal(t, 1, remote.calls["trash:due.pdf"])
	require.Zero(t, remote.calls["trash:future.pdf"])
	require.Zero(t, remote.calls["trash:completed.pdf"])
}
