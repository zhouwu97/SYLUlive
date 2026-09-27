package services

import (
	"testing"

	"shenliyuan/internal/models"
)

func TestReadyPublicImageVariantPathOnlyReturnsReadyPublicVariant(t *testing.T) {
	db := newImageVariantTestDB(t)
	file := createPublicVariantFile(t, db, t.TempDir(), "profile.jpg", "image/jpeg")
	const readyPath = "/uploads/profile_v1_medium.jpg"
	if err := db.Create(&models.ImageVariant{
		FileID: file.ID, Variant: ImageVariantMedium, RecipeVersion: ImageVariantRecipeVersion,
		Status: models.ImageVariantStatusReady, Path: readyPath, MimeType: "image/jpeg",
	}).Error; err != nil {
		t.Fatal(err)
	}

	path, ready, err := ReadyPublicImageVariantPath(
		db,
		"https://example.test/uploads/profile.jpg?cache=1",
		ImageVariantMedium,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !ready || path != readyPath {
		t.Fatalf("未返回 ready 变体: ready=%v path=%q", ready, path)
	}

	if err := db.Model(&models.ImageVariant{}).Where("file_id = ?", file.ID).
		Update("status", models.ImageVariantStatusPending).Error; err != nil {
		t.Fatal(err)
	}
	if _, ready, err = ReadyPublicImageVariantPath(db, file.Path, ImageVariantMedium); err != nil {
		t.Fatal(err)
	} else if ready {
		t.Fatal("pending 变体不应被当作可用预览")
	}

	private := models.File{
		Hash:        "private-profile",
		Path:        "/uploads/private-profile.jpg",
		MimeType:    "image/jpeg",
		AccessScope: models.FileAccessPrivate,
		Status:      models.FileStatusActive,
	}
	if err := db.Create(&private).Error; err != nil {
		t.Fatal(err)
	}
	if _, ready, err = ReadyPublicImageVariantPath(db, private.Path, ImageVariantMedium); err != nil {
		t.Fatal(err)
	} else if ready {
		t.Fatal("私有原图不应返回公开预览")
	}
}
