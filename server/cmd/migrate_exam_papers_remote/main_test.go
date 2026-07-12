package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

type migrationRemoteStub struct {
	metadata map[string]services.StoredExamPaperFile
	errors   map[string]error
}

func (s *migrationRemoteStub) Metadata(ctx context.Context, fileKey string) (services.StoredExamPaperFile, error) {
	if err := ctx.Err(); err != nil {
		return services.StoredExamPaperFile{}, err
	}
	if err := s.errors[fileKey]; err != nil {
		return services.StoredExamPaperFile{}, err
	}
	metadata, ok := s.metadata[fileKey]
	if !ok {
		return services.StoredExamPaperFile{}, services.ErrExamPaperRemoteNotFound
	}
	return metadata, nil
}

type migrationTestEnv struct {
	db     *gorm.DB
	root   string
	remote *migrationRemoteStub
}

func newMigrationTestEnv(t *testing.T) *migrationTestEnv {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+filepath.ToSlash(filepath.Join(t.TempDir(), "migration.db"))+"?mode=rwc"), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, sqlDB.Close()) })
	require.NoError(t, db.AutoMigrate(&models.ExamPaper{}))
	return &migrationTestEnv{
		db: db, root: t.TempDir(),
		remote: &migrationRemoteStub{metadata: make(map[string]services.StoredExamPaperFile), errors: make(map[string]error)},
	}
}

func (e *migrationTestEnv) addPaper(t *testing.T, fileKey string, content []byte) models.ExamPaper {
	t.Helper()
	require.NoError(t, os.WriteFile(filepath.Join(e.root, fileKey), content, 0o600))
	hash := sha256.Sum256(content)
	paper := models.ExamPaper{
		Status: models.ExamPaperStatusPublished, Source: models.ExamPaperSourceAdmin, SubmitterID: 1,
		StorageBackend: models.ExamPaperStorageLocal, CourseName: "迁移测试", AcademicYear: "2025-2026",
		Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal, Title: "迁移测试",
		FileKey: fileKey, FileSize: int64(len(content)), SHA256: hex.EncodeToString(hash[:]),
	}
	require.NoError(t, e.db.Create(&paper).Error)
	e.remote.metadata[fileKey] = services.StoredExamPaperFile{FileKey: fileKey, Size: paper.FileSize, SHA256: paper.SHA256}
	return paper
}

func loadMigrationPaper(t *testing.T, db *gorm.DB, id uint) models.ExamPaper {
	t.Helper()
	var paper models.ExamPaper
	require.NoError(t, db.First(&paper, id).Error)
	return paper
}

func TestMigrationDoesNotMarkRemoteWhenMetadataDiffers(t *testing.T) {
	env := newMigrationTestEnv(t)
	paper := env.addPaper(t, "mismatch.pdf", []byte("actual-pdf-bytes"))
	env.remote.metadata[paper.FileKey] = services.StoredExamPaperFile{FileKey: paper.FileKey, Size: paper.FileSize + 1, SHA256: paper.SHA256}

	summary, err := runMigration(context.Background(), env.db, env.remote, env.root, migrationOptions{Apply: true, ID: paper.ID, PageSize: 10}, &bytes.Buffer{})

	require.Error(t, err)
	require.Equal(t, 1, summary.Failed)
	require.Equal(t, models.ExamPaperStorageLocal, loadMigrationPaper(t, env.db, paper.ID).StorageBackend)
}

func TestMigrationDryRunMatchesWithoutWriting(t *testing.T) {
	env := newMigrationTestEnv(t)
	paper := env.addPaper(t, "dry-run.pdf", []byte("dry-run-content"))

	summary, err := runMigration(context.Background(), env.db, env.remote, env.root, migrationOptions{PageSize: 10}, &bytes.Buffer{})

	require.NoError(t, err)
	require.Equal(t, 1, summary.Verified)
	require.Zero(t, summary.Updated)
	require.Equal(t, models.ExamPaperStorageLocal, loadMigrationPaper(t, env.db, paper.ID).StorageBackend)
}

func TestMigrationApplyUpdatesMatchingRecord(t *testing.T) {
	env := newMigrationTestEnv(t)
	paper := env.addPaper(t, "apply.pdf", []byte("apply-content"))

	summary, err := runMigration(context.Background(), env.db, env.remote, env.root, migrationOptions{Apply: true, PageSize: 10}, &bytes.Buffer{})

	require.NoError(t, err)
	require.Equal(t, 1, summary.Updated)
	require.Equal(t, models.ExamPaperStorageRemote, loadMigrationPaper(t, env.db, paper.ID).StorageBackend)
}

func TestMigrationConditionalUpdateDetectsConcurrentStateChange(t *testing.T) {
	env := newMigrationTestEnv(t)
	paper := env.addPaper(t, "race.pdf", []byte("race-content"))

	beforeUpdate := func(candidate models.ExamPaper) {
		require.NoError(t, env.db.Model(&models.ExamPaper{}).Where("id = ?", candidate.ID).Update("storage_backend", models.ExamPaperStorageRemote).Error)
	}
	summary, err := runMigration(context.Background(), env.db, env.remote, env.root, migrationOptions{Apply: true, ID: paper.ID, PageSize: 10, BeforeUpdate: beforeUpdate}, &bytes.Buffer{})

	require.Error(t, err)
	require.Equal(t, 1, summary.ConcurrentChanges)
}

func TestMigrationConditionalUpdateRejectsChangedFileReference(t *testing.T) {
	env := newMigrationTestEnv(t)
	paper := env.addPaper(t, "reference-race.pdf", []byte("race-content"))

	beforeUpdate := func(candidate models.ExamPaper) {
		require.NoError(t, env.db.Model(&models.ExamPaper{}).Where("id = ?", candidate.ID).Update("file_key", "replacement.pdf").Error)
	}
	summary, err := runMigration(context.Background(), env.db, env.remote, env.root, migrationOptions{Apply: true, ID: paper.ID, PageSize: 10, BeforeUpdate: beforeUpdate}, &bytes.Buffer{})

	require.Error(t, err)
	require.Equal(t, 1, summary.ConcurrentChanges)
	require.Equal(t, models.ExamPaperStorageLocal, loadMigrationPaper(t, env.db, paper.ID).StorageBackend)
}

func TestMigrationRejectsDatabaseMetadataDifferentFromDisk(t *testing.T) {
	env := newMigrationTestEnv(t)
	paper := env.addPaper(t, "database-mismatch.pdf", []byte("actual-content"))
	require.NoError(t, env.db.Model(&models.ExamPaper{}).Where("id = ?", paper.ID).Update("sha256", strings.Repeat("a", 64)).Error)

	summary, err := runMigration(context.Background(), env.db, env.remote, env.root, migrationOptions{Apply: true, ID: paper.ID, PageSize: 10}, &bytes.Buffer{})

	require.Error(t, err)
	require.Equal(t, 1, summary.Failed)
	require.Equal(t, models.ExamPaperStorageLocal, loadMigrationPaper(t, env.db, paper.ID).StorageBackend)
}

func TestLocalMetadataUsesActualFileHashAndSize(t *testing.T) {
	root := t.TempDir()
	content := []byte("actual-disk-content")
	require.NoError(t, os.WriteFile(filepath.Join(root, "paper.pdf"), content, 0o600))

	metadata, err := localMetadata(root, "paper.pdf")

	require.NoError(t, err)
	expected := sha256.Sum256(content)
	require.Equal(t, int64(len(content)), metadata.Size)
	require.Equal(t, hex.EncodeToString(expected[:]), metadata.SHA256)
}

func TestLocalMetadataSupportsEncryptedPDFBytesWithoutParsing(t *testing.T) {
	root := t.TempDir()
	content := []byte("%PDF-1.7\n/Encrypt 99 0 R\n%%EOF")
	require.NoError(t, os.WriteFile(filepath.Join(root, "encrypted.pdf"), content, 0o600))

	metadata, err := localMetadata(root, "encrypted.pdf")

	require.NoError(t, err)
	require.Equal(t, int64(len(content)), metadata.Size)
}

func TestLocalMetadataRejectsMissingSymlinkAndUnsafePath(t *testing.T) {
	root := t.TempDir()
	outside := filepath.Join(t.TempDir(), "outside.pdf")
	require.NoError(t, os.WriteFile(outside, []byte("outside"), 0o600))
	symlink := filepath.Join(root, "link.pdf")
	symlinkErr := os.Symlink(outside, symlink)

	_, err := localMetadata(root, "missing.pdf")
	require.Error(t, err)
	_, err = localMetadata(root, "../outside.pdf")
	require.Error(t, err)
	if symlinkErr == nil {
		_, err = localMetadata(root, "link.pdf")
		require.Error(t, err)
	}
}

func TestMigrationBatchContinuesAndReturnsFailureSummary(t *testing.T) {
	env := newMigrationTestEnv(t)
	good := env.addPaper(t, "good.pdf", []byte("good"))
	bad := env.addPaper(t, "bad.pdf", []byte("bad"))
	env.remote.errors[bad.FileKey] = errors.New("远端暂时不可用")
	var output bytes.Buffer

	summary, err := runMigration(context.Background(), env.db, env.remote, env.root, migrationOptions{Apply: true, PageSize: 1}, &output)

	require.Error(t, err)
	require.Equal(t, 2, summary.Scanned)
	require.Equal(t, 1, summary.Updated)
	require.Equal(t, 1, summary.Failed)
	require.Equal(t, models.ExamPaperStorageRemote, loadMigrationPaper(t, env.db, good.ID).StorageBackend)
	require.Equal(t, models.ExamPaperStorageLocal, loadMigrationPaper(t, env.db, bad.ID).StorageBackend)
	require.NotContains(t, output.String(), "token")
}

func TestMigrationOnlyProcessesActiveLocalRecordsWithFileKeys(t *testing.T) {
	env := newMigrationTestEnv(t)
	active := env.addPaper(t, "active.pdf", []byte("active"))
	unpublished := env.addPaper(t, "unpublished.pdf", []byte("old"))
	require.NoError(t, env.db.Model(&models.ExamPaper{}).Where("id = ?", unpublished.ID).Update("status", models.ExamPaperStatusUnpublished).Error)
	remote := env.addPaper(t, "already-remote.pdf", []byte("remote"))
	require.NoError(t, env.db.Model(&models.ExamPaper{}).Where("id = ?", remote.ID).Update("storage_backend", models.ExamPaperStorageRemote).Error)

	summary, err := runMigration(context.Background(), env.db, env.remote, env.root, migrationOptions{Apply: true, PageSize: 1}, &bytes.Buffer{})

	require.NoError(t, err)
	require.Equal(t, 1, summary.Scanned)
	require.Equal(t, models.ExamPaperStorageRemote, loadMigrationPaper(t, env.db, active.ID).StorageBackend)
	require.Equal(t, models.ExamPaperStorageLocal, loadMigrationPaper(t, env.db, unpublished.ID).StorageBackend)
}

func TestParseMigrationFlagsDefaultsToDryRunAndRejectsConflicts(t *testing.T) {
	options, err := parseMigrationFlags(nil)
	require.NoError(t, err)
	require.False(t, options.Apply)
	require.Equal(t, defaultMigrationPageSize, options.PageSize)

	_, err = parseMigrationFlags([]string{"--apply", "--dry-run"})
	require.Error(t, err)
	_, err = parseMigrationFlags([]string{"--apply=false", "--dry-run"})
	require.Error(t, err)
	_, err = parseMigrationFlags([]string{"--id", "0"})
	require.Error(t, err)
	_, err = parseMigrationFlags([]string{"--page-size", "0"})
	require.Error(t, err)

	options, err = parseMigrationFlags([]string{"--apply", "--id", "42", "--page-size", "25"})
	require.NoError(t, err)
	require.True(t, options.Apply)
	require.Equal(t, uint(42), options.ID)
	require.Equal(t, 25, options.PageSize)
}

func TestMigrationHonorsCanceledContext(t *testing.T) {
	env := newMigrationTestEnv(t)
	env.addPaper(t, "cancel.pdf", []byte("cancel"))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err := runMigration(ctx, env.db, env.remote, env.root, migrationOptions{PageSize: 10}, &bytes.Buffer{})

	require.ErrorIs(t, err, context.Canceled)
}

func TestMigrationSpecificMissingIDReturnsFailure(t *testing.T) {
	env := newMigrationTestEnv(t)

	summary, err := runMigration(context.Background(), env.db, env.remote, env.root, migrationOptions{ID: 404, PageSize: 10}, &bytes.Buffer{})

	require.Error(t, err)
	require.Zero(t, summary.Scanned)
}

func TestSummaryOutputDoesNotExposeRemoteErrorsAsCredentials(t *testing.T) {
	var output bytes.Buffer
	writeSummary(&output, migrationSummary{Scanned: 2, Verified: 1, Failed: 1}, false)
	require.True(t, strings.Contains(output.String(), "failed=1"))
}
