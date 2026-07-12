package models

import (
	"strings"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func TestExamPaperStorageModelsDefaultToLocalAndCreateOpenSession(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&User{},
		&ExamPaper{},
		&ExamPaperUploadSession{},
		&ExamPaperStorageJob{},
	))

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
