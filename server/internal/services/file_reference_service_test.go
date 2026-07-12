package services

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"shenliyuan/internal/models"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func newFileReferenceTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:fileref?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.File{}, &models.FileUploadGrant{}); err != nil {
		t.Fatal(err)
	}
	return db
}

func TestValidateImageFileIDsChecksOrderOwnershipAndDisk(t *testing.T) {
	db := newFileReferenceTestDB(t)
	uploadDir := t.TempDir()
	t.Setenv("UPLOAD_DIR", uploadDir)
	for _, name := range []string{"a.png", "b.png"} {
		if err := os.WriteFile(filepath.Join(uploadDir, name), []byte("image"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	files := []models.File{
		{Hash: "a", Path: "/uploads/a.png", MimeType: "image/png", Size: 5, UploaderID: 7},
		{Hash: "b", Path: "/uploads/b.png", MimeType: "image/png", Size: 5, UploaderID: 7},
	}
	if err := db.Create(&files).Error; err != nil {
		t.Fatal(err)
	}
	for _, file := range files {
		if err := db.Create(&models.FileUploadGrant{FileID: file.ID, UserID: 7}).Error; err != nil {
			t.Fatal(err)
		}
	}

	ordered, err := ValidateImageFileIDs(db, []uint{files[1].ID, files[0].ID}, 9, 7)
	if err != nil {
		t.Fatal(err)
	}
	if ordered[0].ID != files[1].ID || ordered[1].ID != files[0].ID {
		t.Fatalf("图片顺序未保持: %#v", ordered)
	}
	if _, err := ValidateImageFileIDs(db, []uint{files[0].ID}, 9, 8); !errors.Is(err, ErrInvalidImageFileReference) {
		t.Fatalf("预期拒绝无权引用，得到 %v", err)
	}
}

func TestValidateImageFileIDsRejectsPartialAndInvalidInputs(t *testing.T) {
	db := newFileReferenceTestDB(t)
	t.Setenv("UPLOAD_DIR", t.TempDir())
	if _, err := ParseImageFileIDs("1,invalid"); !errors.Is(err, ErrInvalidImageFileReference) {
		t.Fatalf("预期拒绝非法 ID，得到 %v", err)
	}
	if _, err := ValidateImageFileIDs(db, []uint{1, 1}, 9); !errors.Is(err, ErrInvalidImageFileReference) {
		t.Fatalf("预期拒绝重复 ID，得到 %v", err)
	}
	if _, err := ValidateImageFileIDs(db, []uint{1, 2}, 1); !errors.Is(err, ErrInvalidImageFileReference) {
		t.Fatalf("预期拒绝超量图片，得到 %v", err)
	}
	file := models.File{Hash: "missing", Path: "/uploads/missing.png", MimeType: "image/png", Size: 1}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	if _, err := ValidateImageFileIDs(db, []uint{file.ID}, 9); !errors.Is(err, ErrInvalidImageFileReference) {
		t.Fatalf("预期拒绝物理文件缺失，得到 %v", err)
	}
}
