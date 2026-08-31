package services

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"shenliyuan/internal/models"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func newFileReferenceTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+strings.NewReplacer("/", "_", "\\", "_").Replace(t.Name())+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.File{}, &models.FileUploadGrant{}, &models.ImageVariant{}); err != nil {
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

func TestClaimPublicImagePathsNormalizesLegacyReferences(t *testing.T) {
	db := newFileReferenceTestDB(t)
	files := []models.File{
		{Hash: "path-a", Path: "/uploads/path-a.png", MimeType: "image/png"},
		{Hash: "path-b", Path: "uploads/path-b.png", MimeType: "image/png"},
	}
	if err := db.Create(&files).Error; err != nil {
		t.Fatal(err)
	}
	if err := ClaimPublicImagePaths(db, "/uploads/path-a.png?v=1", "/api/uploads/path-b.png", "https://cdn.example.com/image.png"); err != nil {
		t.Fatal(err)
	}
	var stored []models.File
	if err := db.Order("id ASC").Find(&stored).Error; err != nil {
		t.Fatal(err)
	}
	for _, file := range stored {
		if file.Status != "active" || file.AccessScope != models.FileAccessPublic || file.ClaimedAt == nil {
			t.Fatalf("file was not claimed public: %+v", file)
		}
	}
}

func TestClaimPublicImageFilesCreatesVersionedTasksExactlyOnce(t *testing.T) {
	db := newFileReferenceTestDB(t)
	files := []models.File{
		{Hash: "variant-jpeg", Path: "/uploads/variant-jpeg.jpg", MimeType: "image/jpeg"},
		{Hash: "variant-png", Path: "/uploads/variant-png.png", MimeType: "image/png"},
		{Hash: "variant-gif", Path: "/uploads/variant-gif.gif", MimeType: "image/gif"},
	}
	if err := db.Create(&files).Error; err != nil {
		t.Fatal(err)
	}
	ids := []uint{files[0].ID, files[1].ID, files[2].ID}
	if err := ClaimPublicImageFiles(db, ids); err != nil {
		t.Fatal(err)
	}
	if err := ClaimPublicImageFiles(db, ids); err != nil {
		t.Fatal(err)
	}

	var variants []models.ImageVariant
	if err := db.Order("file_id, variant").Find(&variants).Error; err != nil {
		t.Fatal(err)
	}
	if len(variants) != 6 {
		t.Fatalf("变体任务数量=%d，期望 6", len(variants))
	}
	for _, variant := range variants {
		if variant.RecipeVersion != 1 {
			t.Fatalf("配方版本=%d，期望 1", variant.RecipeVersion)
		}
		if variant.Status != "pending" {
			t.Fatalf("任务状态=%q", variant.Status)
		}
		if variant.FileID == files[2].ID && variant.MimeType != "image/jpeg" {
			t.Fatalf("GIF 静态预览应使用 JPEG，得到 %+v", variant)
		}
		if variant.FileID == files[2].ID && !strings.Contains(variant.Path, "_v1_") {
			t.Fatalf("GIF 任务路径应保留版本信息，得到 %+v", variant)
		}
	}
}

func TestClaimPublicImagePathsForUserRejectsPrivateForeignFile(t *testing.T) {
	db := newFileReferenceTestDB(t)
	file := models.File{Hash: "foreign-path", Path: "/uploads/foreign-path.png", MimeType: "image/png", UploaderID: 7}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	if err := ClaimPublicImagePathsForUser(db, 8, file.Path); !errors.Is(err, ErrInvalidImageFileReference) {
		t.Fatalf("expected foreign private path to be rejected, got %v", err)
	}
}

func TestClaimPrivateFilesActivatesButKeepsPrivate(t *testing.T) {
	db := newFileReferenceTestDB(t)
	files := []models.File{
		{Hash: "p-a", Path: "/uploads/p-a.png", MimeType: "image/png", Size: 1, UploaderID: 7, AccessScope: models.FileAccessPrivate},
		{Hash: "p-b", Path: "/uploads/p-b.png", MimeType: "image/png", Size: 2, UploaderID: 7, AccessScope: models.FileAccessPrivate},
	}
	if err := db.Create(&files).Error; err != nil {
		t.Fatal(err)
	}
	if err := ClaimPrivateFiles(db, []uint{files[0].ID, files[1].ID}); err != nil {
		t.Fatal(err)
	}
	var stored []models.File
	if err := db.Order("id ASC").Find(&stored).Error; err != nil {
		t.Fatal(err)
	}
	for _, file := range stored {
		if file.Status != "active" || file.ClaimedAt == nil {
			t.Fatalf("file was not activated: %+v", file)
		}
		if file.AccessScope != models.FileAccessPrivate {
			t.Fatalf("ClaimPrivateFiles must not flip access_scope to public, got %q", file.AccessScope)
		}
	}
	var variantCount int64
	if err := db.Model(&models.ImageVariant{}).Count(&variantCount).Error; err != nil {
		t.Fatal(err)
	}
	if variantCount != 0 {
		t.Fatalf("私有声明不应创建变体任务，得到 %d 条", variantCount)
	}
}

// 迁移菜品实拍、帖子、回复等可能共享同一 SHA 文件的公开引用表。
func newReconcileTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+strings.NewReplacer("/", "_", "\\", "_").Replace(t.Name())+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.File{},
		&models.CanteenDish{},
		&models.CanteenDishPhoto{},
		&models.Post{},
		&models.PostImage{},
		&models.Reply{},
		&models.ReplyImage{},
	); err != nil {
		t.Fatal(err)
	}
	return db
}

// 回归：菜品实拍与正常帖子共用同一文件，下架实拍后文件必须保持 public。
func TestReconcileKeepsPublicWhenPostSharesFile(t *testing.T) {
	db := newReconcileTestDB(t)
	if err := db.Create(&models.User{ID: 1, Nickname: "u"}).Error; err != nil {
		t.Fatal(err)
	}
	dish := models.CanteenDish{ID: 1, CanteenID: 1, Name: "水饺", NormalizedName: "水饺", CreatedBy: 1}
	if err := db.Create(&dish).Error; err != nil {
		t.Fatal(err)
	}
	file := models.File{ID: 1, Path: "/uploads/shared.png", MimeType: "image/png", Hash: "shared", AccessScope: models.FileAccessPublic}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	// 正常帖子引用同一文件
	post := models.Post{ID: 1, Title: "t", BoardID: 1, AuthorID: 1, Status: models.PostStatusNormal}
	if err := db.Create(&post).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.PostImage{PostID: post.ID, FileID: file.ID}).Error; err != nil {
		t.Fatal(err)
	}
	// 菜品实拍引用同一文件
	photo := models.CanteenDishPhoto{DishID: dish.ID, FileID: file.ID, UserID: 1, Status: models.DishPhotoStatusApproved}
	if err := db.Create(&photo).Error; err != nil {
		t.Fatal(err)
	}

	// 模拟下架：实拍 approved → archived，然后 reconcile
	if err := db.Model(&models.CanteenDishPhoto{}).Where("id = ?", photo.ID).
		Update("status", models.DishPhotoStatusArchived).Error; err != nil {
		t.Fatal(err)
	}
	if err := ReconcileFilePublicAccess(db, file.ID); err != nil {
		t.Fatal(err)
	}

	var after models.File
	if err := db.First(&after, file.ID).Error; err != nil {
		t.Fatal(err)
	}
	if after.AccessScope != models.FileAccessPublic {
		t.Fatalf("帖子仍引用该文件，reconcile 后 scope=%q want public", after.AccessScope)
	}
}

// 回归：菜品实拍与正常回复共用同一文件，下架实拍后文件必须保持 public。
func TestReconcileKeepsPublicWhenReplySharesFile(t *testing.T) {
	db := newReconcileTestDB(t)
	if err := db.Create(&models.User{ID: 1, Nickname: "u"}).Error; err != nil {
		t.Fatal(err)
	}
	dish := models.CanteenDish{ID: 1, CanteenID: 1, Name: "排骨饭", NormalizedName: "排骨饭", CreatedBy: 1}
	if err := db.Create(&dish).Error; err != nil {
		t.Fatal(err)
	}
	file := models.File{ID: 1, Path: "/uploads/shared-reply.png", MimeType: "image/png", Hash: "shared-reply", AccessScope: models.FileAccessPublic}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	// 正常回复引用同一文件
	post := models.Post{ID: 1, Title: "t", BoardID: 1, AuthorID: 1, Status: models.PostStatusNormal}
	if err := db.Create(&post).Error; err != nil {
		t.Fatal(err)
	}
	reply := models.Reply{ID: 1, PostID: post.ID, AuthorID: 1, Content: "c", Status: models.ReplyStatusNormal}
	if err := db.Create(&reply).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.ReplyImage{ReplyID: reply.ID, FileID: file.ID}).Error; err != nil {
		t.Fatal(err)
	}
	// 菜品实拍引用同一文件
	photo := models.CanteenDishPhoto{DishID: dish.ID, FileID: file.ID, UserID: 1, Status: models.DishPhotoStatusApproved}
	if err := db.Create(&photo).Error; err != nil {
		t.Fatal(err)
	}

	// 模拟下架：实拍 approved → archived，然后 reconcile
	if err := db.Model(&models.CanteenDishPhoto{}).Where("id = ?", photo.ID).
		Update("status", models.DishPhotoStatusArchived).Error; err != nil {
		t.Fatal(err)
	}
	if err := ReconcileFilePublicAccess(db, file.ID); err != nil {
		t.Fatal(err)
	}

	var after models.File
	if err := db.First(&after, file.ID).Error; err != nil {
		t.Fatal(err)
	}
	if after.AccessScope != models.FileAccessPublic {
		t.Fatalf("回复仍引用该文件，reconcile 后 scope=%q want public", after.AccessScope)
	}
}
