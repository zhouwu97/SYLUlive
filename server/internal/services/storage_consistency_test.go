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

func TestStorageConsistencyScannerReportsMissingOrphanAndReferencedTemporaryFiles(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "test.db")), &gorm.Config{})
	require.NoError(t, err)
	t.Cleanup(func() {
		if sqlDB, closeErr := db.DB(); closeErr == nil {
			_ = sqlDB.Close()
		}
	})
	require.NoError(t, db.AutoMigrate(&models.File{}, &models.ImageVariant{}))
	require.NoError(t, db.Exec("CREATE TABLE IF NOT EXISTS post_images (id INTEGER PRIMARY KEY, file_id INTEGER NOT NULL)").Error)
	dir := t.TempDir()

	missing := models.File{Hash: "missing", Path: "/uploads/aa/missing.png", Size: 1, MimeType: "image/png", UploaderID: 1, Status: models.FileStatusActive, AccessScope: models.FileAccessPrivate, CreatedAt: time.Now()}
	referenced := models.File{Hash: "referenced", Path: "/uploads/bb/referenced.png", Size: 2, MimeType: "image/png", UploaderID: 1, Status: models.FileStatusTemporary, AccessScope: models.FileAccessPrivate, CreatedAt: time.Now()}
	require.NoError(t, db.Create(&missing).Error)
	require.NoError(t, db.Create(&referenced).Error)
	require.NoError(t, db.Exec("INSERT INTO post_images(file_id) VALUES (?)", referenced.ID).Error)
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "bb"), 0755))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "bb", "referenced.png"), []byte("ok"), 0644))
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "cc"), 0755))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "cc", "orphan.png"), []byte("orphan"), 0644))

	scanner := NewStorageConsistencyScanner(db, dir)
	report, err := scanner.Run(t.Context())
	require.NoError(t, err)
	require.Equal(t, 1, report.MissingPhysical)
	require.Equal(t, 1, report.OrphanPhysical)
	require.Equal(t, 1, report.TemporaryReferenced)
}
