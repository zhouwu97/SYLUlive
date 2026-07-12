package services

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"

	"shenliyuan/internal/models"
)

type storageMaintenanceRemoteStub struct {
	mu          sync.Mutex
	metadata    map[string]StoredExamPaperFile
	errors      map[string]error
	calls       []string
	maintenance ExamPaperRemoteMaintenanceResult
	cancel      context.CancelFunc
}

func (s *storageMaintenanceRemoteStub) Metadata(ctx context.Context, key string) (StoredExamPaperFile, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls = append(s.calls, key)
	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}
	if err := s.errors[key]; err != nil {
		return StoredExamPaperFile{}, err
	}
	return s.metadata[key], nil
}

func (s *storageMaintenanceRemoteStub) Maintenance(context.Context) (ExamPaperRemoteMaintenanceResult, error) {
	return s.maintenance, nil
}

func TestExamPaperStorageMaintenanceReportsMissingMismatchAndContinues(t *testing.T) {
	db := openStorageJobTestDB(t)
	papers := []models.ExamPaper{
		{Status: models.ExamPaperStatusPublished, Source: models.ExamPaperSourceUser, SubmitterID: 1, StorageBackend: models.ExamPaperStorageRemote, CourseName: "A", AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal, Title: "A", FileKey: "ok.pdf", FileSize: 10, SHA256: strings.Repeat("a", 64)},
		{Status: models.ExamPaperStatusPending, Source: models.ExamPaperSourceUser, SubmitterID: 1, StorageBackend: models.ExamPaperStorageRemote, CourseName: "B", AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal, Title: "B", FileKey: "missing.pdf", FileSize: 20, SHA256: strings.Repeat("b", 64)},
		{Status: models.ExamPaperStatusPublished, Source: models.ExamPaperSourceUser, SubmitterID: 1, StorageBackend: models.ExamPaperStorageRemote, CourseName: "C", AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal, Title: "C", FileKey: "mismatch.pdf", FileSize: 30, SHA256: strings.Repeat("c", 64)},
		{Status: models.ExamPaperStatusPublished, Source: models.ExamPaperSourceUser, SubmitterID: 1, StorageBackend: models.ExamPaperStorageRemote, CourseName: "D", AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal, Title: "D", FileKey: "error.pdf", FileSize: 40, SHA256: strings.Repeat("d", 64)},
		{Status: models.ExamPaperStatusUnpublished, Source: models.ExamPaperSourceUser, SubmitterID: 1, StorageBackend: models.ExamPaperStorageRemote, CourseName: "E", AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal, Title: "E", FileKey: "ignored.pdf", FileSize: 50, SHA256: strings.Repeat("e", 64)},
	}
	for index := range papers {
		require.NoError(t, db.Create(&papers[index]).Error)
	}
	remote := &storageMaintenanceRemoteStub{
		metadata: map[string]StoredExamPaperFile{
			"ok.pdf":       {FileKey: "ok.pdf", Size: 10, SHA256: strings.Repeat("a", 64)},
			"mismatch.pdf": {FileKey: "mismatch.pdf", Size: 31, SHA256: strings.Repeat("c", 64)},
		},
		errors:      map[string]error{"missing.pdf": ErrExamPaperRemoteNotFound, "error.pdf": errors.New("网络失败")},
		maintenance: ExamPaperRemoteMaintenanceResult{UnclaimedFilesRemoved: 2, TrashFilesRemoved: 3, DiskUsagePercent: 61.5},
	}
	service := NewExamPaperStorageMaintenance(db, remote, nil)

	report, err := service.Run(context.Background())
	require.NoError(t, err)
	require.Equal(t, 4, report.Referenced)
	require.Equal(t, 1, report.Missing)
	require.Equal(t, 1, report.Mismatched)
	require.Equal(t, 1, report.MetadataErrors)
	require.Equal(t, 2, report.OrphanFilesRemoved)
	require.Equal(t, 3, report.TrashFilesRemoved)
	require.Equal(t, 61.5, report.DiskUsagePercent)
	require.Len(t, remote.calls, 4)
}

func TestExamPaperStorageMaintenanceStopsOnContextCancellation(t *testing.T) {
	db := openStorageJobTestDB(t)
	for index := 0; index < 3; index++ {
		require.NoError(t, db.Create(&models.ExamPaper{
			Status: models.ExamPaperStatusPublished, Source: models.ExamPaperSourceUser, SubmitterID: 1,
			StorageBackend: models.ExamPaperStorageRemote, CourseName: "A", AcademicYear: "2025-2026",
			Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal, Title: "A",
			FileKey: string(rune('a'+index)) + ".pdf", FileSize: 10, SHA256: strings.Repeat("a", 64),
		}).Error)
	}
	ctx, cancel := context.WithCancel(context.Background())
	remote := &storageMaintenanceRemoteStub{metadata: map[string]StoredExamPaperFile{}, cancel: cancel}
	service := NewExamPaperStorageMaintenance(db, remote, nil)

	_, err := service.Run(ctx)
	require.ErrorIs(t, err, context.Canceled)
	require.Len(t, remote.calls, 1)
}
