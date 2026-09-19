package services

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestTemporaryFileJanitorDeletesOnlyUnclaimedUnreferencedFiles(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "test.db")), &gorm.Config{})
	require.NoError(t, err)
	t.Cleanup(func() {
		if sqlDB, closeErr := db.DB(); closeErr == nil {
			_ = sqlDB.Close()
		}
	})
	require.NoError(t, db.AutoMigrate(&models.File{}, &models.FileUploadGrant{}))
	require.NoError(t, db.Exec("CREATE TABLE IF NOT EXISTS post_images (id INTEGER PRIMARY KEY, file_id INTEGER NOT NULL)").Error)
	dir := t.TempDir()
	now := time.Date(2026, 9, 20, 8, 0, 0, 0, time.UTC)

	writeFile := func(relative string, content string) {
		path := filepath.Join(dir, filepath.FromSlash(relative))
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0755))
		require.NoError(t, os.WriteFile(path, []byte(content), 0644))
	}
	old := now.Add(-8 * time.Hour)
	deletable := models.File{Hash: "delete", Path: "/uploads/aa/delete.png", Size: 3, MimeType: "image/png", UploaderID: 1, Status: models.FileStatusTemporary, AccessScope: models.FileAccessPrivate, CreatedAt: old}
	referenced := models.File{Hash: "keep", Path: "/uploads/bb/keep.png", Size: 4, MimeType: "image/png", UploaderID: 1, Status: models.FileStatusTemporary, AccessScope: models.FileAccessPrivate, CreatedAt: old}
	claimed := models.File{Hash: "claimed", Path: "/uploads/cc/claimed.png", Size: 7, MimeType: "image/png", UploaderID: 1, Status: models.FileStatusTemporary, AccessScope: models.FileAccessPrivate, ClaimedAt: ptrUploadTime(now.Add(-7 * time.Hour)), CreatedAt: old}
	require.NoError(t, db.Create(&deletable).Error)
	require.NoError(t, db.Create(&referenced).Error)
	require.NoError(t, db.Create(&claimed).Error)
	require.NoError(t, db.Exec("INSERT INTO post_images(file_id) VALUES (?)", referenced.ID).Error)
	writeFile("aa/delete.png", "del")
	writeFile("bb/keep.png", "keep")
	writeFile("cc/claimed.png", "claim")

	janitor := NewTemporaryFileJanitor(db, dir, TemporaryFileJanitorConfig{TTL: 6 * time.Hour, BatchSize: 20})
	janitor.SetNow(func() time.Time { return now })
	report, err := janitor.Run(t.Context())
	require.NoError(t, err)
	require.Equal(t, 1, report.Removed)
	require.Equal(t, 1, report.RetainedReferenced)
	require.NoFileExists(t, filepath.Join(dir, "aa", "delete.png"))
	require.FileExists(t, filepath.Join(dir, "bb", "keep.png"))
	require.FileExists(t, filepath.Join(dir, "cc", "claimed.png"))
	var gone models.File
	require.ErrorIs(t, db.First(&gone, deletable.ID).Error, gorm.ErrRecordNotFound)
	var kept models.File
	require.NoError(t, db.First(&kept, referenced.ID).Error)
	require.Equal(t, models.FileStatusTemporary, kept.Status)
}

func TestTemporaryFileJanitorRetriesDeletingRowWhenPhysicalFileIsMissing(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "test.db")), &gorm.Config{})
	require.NoError(t, err)
	t.Cleanup(func() {
		if sqlDB, closeErr := db.DB(); closeErr == nil {
			_ = sqlDB.Close()
		}
	})
	require.NoError(t, db.AutoMigrate(&models.File{}, &models.FileUploadGrant{}))
	dir := t.TempDir()
	file := models.File{Hash: "missing", Path: "/uploads/missing.png", Size: 1, MimeType: "image/png", UploaderID: 1, Status: models.FileStatusDeleting, AccessScope: models.FileAccessPrivate, CreatedAt: time.Now().Add(-time.Hour)}
	require.NoError(t, db.Create(&file).Error)
	janitor := NewTemporaryFileJanitor(db, dir, TemporaryFileJanitorConfig{TTL: time.Hour, BatchSize: 10})
	report, err := janitor.Run(t.Context())
	require.NoError(t, err)
	require.Equal(t, 1, report.Removed)
	require.ErrorIs(t, db.First(&models.File{}, file.ID).Error, gorm.ErrRecordNotFound)
}

func TestTemporaryFileJanitorHonorsNotBeforeForHistoricalBacklog(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "test.db")), &gorm.Config{})
	require.NoError(t, err)
	t.Cleanup(func() {
		if sqlDB, closeErr := db.DB(); closeErr == nil {
			_ = sqlDB.Close()
		}
	})
	require.NoError(t, db.AutoMigrate(&models.File{}, &models.FileUploadGrant{}))
	dir := t.TempDir()
	created := time.Date(2026, 9, 19, 8, 0, 0, 0, time.UTC)
	file := models.File{Hash: "historical", Path: "/uploads/aa/historical.png", Size: 1, MimeType: "image/png", UploaderID: 1, Status: models.FileStatusTemporary, AccessScope: models.FileAccessPrivate, CreatedAt: created}
	require.NoError(t, db.Create(&file).Error)
	path := filepath.Join(dir, "aa", "historical.png")
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0755))
	require.NoError(t, os.WriteFile(path, []byte("x"), 0644))

	janitor := NewTemporaryFileJanitor(db, dir, TemporaryFileJanitorConfig{
		TTL:       time.Hour,
		BatchSize: 10,
		NotBefore: time.Date(2026, 9, 20, 8, 0, 0, 0, time.UTC),
	})
	janitor.SetNow(func() time.Time { return time.Date(2026, 9, 20, 10, 0, 0, 0, time.UTC) })
	report, err := janitor.Run(t.Context())
	require.NoError(t, err)
	require.Zero(t, report.Removed)
	require.FileExists(t, path)
	var retained models.File
	require.NoError(t, db.First(&retained, file.ID).Error)
	require.Equal(t, models.FileStatusTemporary, retained.Status)
}

func ptrUploadTime(value time.Time) *time.Time { return &value }
