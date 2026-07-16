package models

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func TestExamPaperStorageModelsDefaultToLocalAndCreateOpenSession(t *testing.T) {
	db := openExamPaperStorageModelTestDB(t)

	user := User{
		StudentID:    "exam-storage-user",
		PasswordHash: "test-password",
		Nickname:     "试卷投稿人",
	}
	require.NoError(t, db.Create(&user).Error)

	paper := ExamPaper{
		Status:       ExamPaperStatusPending,
		Source:       ExamPaperSourceUser,
		SubmitterID:  user.ID,
		CourseName:   "高等数学",
		AcademicYear: "2025-2026",
		Semester:     ExamPaperSemesterFirst,
		ExamType:     ExamPaperTypeFinal,
		Title:        "高等数学",
		FileKey:      "paper.pdf",
		FileSize:     10,
		SHA256:       strings.Repeat("a", 64),
	}
	require.NoError(t, db.Create(&paper).Error)
	require.Equal(t, ExamPaperStorageLocal, paper.StorageBackend)

	expiresAt := time.Now().Add(10 * time.Minute)
	metadata := ExamPaperMetadata{
		CourseName:   "高等数学",
		AcademicYear: "2025-2026",
		Semester:     ExamPaperSemesterFirst,
		ExamType:     ExamPaperTypeFinal,
		Title:        "高等数学",
	}
	session := NewExamPaperUploadSession("session-1", user.ID, metadata, 1024, expiresAt)
	require.Equal(t, ExamPaperUploadOpen, session.Status)
	require.Equal(t, "session-1", session.ID)
	require.Equal(t, user.ID, session.SubmitterID)
	require.Equal(t, metadata.CourseName, session.CourseName)
	require.Equal(t, metadata.AcademicYear, session.AcademicYear)
	require.Equal(t, metadata.Semester, session.Semester)
	require.Equal(t, metadata.ExamType, session.ExamType)
	require.Equal(t, metadata.Title, session.Title)
	require.Equal(t, int64(1024), session.ExpectedSize)
	require.Equal(t, expiresAt, session.ExpiresAt)
}

func TestExamPaperStorageRemoteBackendPersists(t *testing.T) {
	db := openExamPaperStorageModelTestDB(t)
	user := User{
		StudentID:    "remote-storage-user",
		PasswordHash: "test-password",
		Nickname:     "远端试卷投稿人",
	}
	require.NoError(t, db.Create(&user).Error)

	paper := ExamPaper{
		Status:         ExamPaperStatusPending,
		Source:         ExamPaperSourceUser,
		SubmitterID:    user.ID,
		StorageBackend: ExamPaperStorageRemote,
		CourseName:     "大学物理",
		AcademicYear:   "2025-2026",
		Semester:       ExamPaperSemesterSecond,
		ExamType:       ExamPaperTypeFinal,
		Title:          "大学物理",
		FileKey:        "remote-paper.pdf",
		FileSize:       20,
		SHA256:         strings.Repeat("b", 64),
	}
	require.NoError(t, db.Create(&paper).Error)

	var reloaded ExamPaper
	require.NoError(t, db.First(&reloaded, paper.ID).Error)
	require.Equal(t, ExamPaperStorageRemote, reloaded.StorageBackend)
}

func TestExamPaperStorageJobScheduleAndCompletedIndex(t *testing.T) {
	db := openExamPaperStorageModelTestDB(t)
	nextAttemptField, ok := reflect.TypeOf(ExamPaperStorageJob{}).FieldByName("NextAttemptAt")
	require.True(t, ok)
	require.Equal(t, reflect.Struct, nextAttemptField.Type.Kind())

	scheduledAt := time.Now().Add(time.Minute).Truncate(time.Millisecond)
	job := ExamPaperStorageJob{
		StorageBackend: ExamPaperStorageRemote,
		FileKey:        "paper-to-delete.pdf",
		Operation:      "delete",
		NextAttemptAt:  scheduledAt,
	}
	require.NoError(t, db.Create(&job).Error)

	var reloaded ExamPaperStorageJob
	require.NoError(t, db.First(&reloaded, job.ID).Error)
	require.WithinDuration(t, scheduledAt, reloaded.NextAttemptAt, time.Millisecond)
	require.True(t, db.Migrator().HasIndex(&ExamPaperStorageJob{}, "CompletedAt"))
}

func TestExamPaperStorageModelsHideInternalFileReferencesFromJSON(t *testing.T) {
	sessionJSON, err := json.Marshal(ExamPaperUploadSession{
		StorageKey: "internal-session-storage-key",
		SHA256:     strings.Repeat("c", 64),
	})
	require.NoError(t, err)
	require.NotContains(t, string(sessionJSON), "storage_key")
	require.NotContains(t, string(sessionJSON), "internal-session-storage-key")
	require.NotContains(t, string(sessionJSON), "sha256")
	require.NotContains(t, string(sessionJSON), strings.Repeat("c", 64))

	jobJSON, err := json.Marshal(ExamPaperStorageJob{
		StorageBackend: ExamPaperStorageRemote,
		FileKey:        "internal-job-file-key",
	})
	require.NoError(t, err)
	require.NotContains(t, string(jobJSON), "storage_backend")
	require.NotContains(t, string(jobJSON), "file_key")
	require.NotContains(t, string(jobJSON), "internal-job-file-key")
}

func openExamPaperStorageModelTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&User{},
		&ExamPaper{},
		&ExamPaperUploadSession{},
		&ExamPaperStorageJob{},
	))
	return db
}
