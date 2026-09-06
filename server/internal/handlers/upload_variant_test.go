package handlers

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
)

func TestImageVariantRequestRecognizesVersionedAndLegacyPaths(t *testing.T) {
	variant, original, legacy := imageVariantRequest("ab/hash_v1_medium.png")
	if variant != "medium" || original != "ab/hash.png" || legacy {
		t.Fatalf("variant=%q original=%q legacy=%v", variant, original, legacy)
	}
	variant, original, legacy = imageVariantRequest("ab/hash_medium.png")
	if variant != "medium" || original != "ab/hash.png" || !legacy {
		t.Fatalf("旧变体路径解析错误: variant=%q original=%q legacy=%v", variant, original, legacy)
	}
}

func TestServePublicProvidesReadyVersionedVariant(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newUploadTestDB(t)
	uploadDir := t.TempDir()
	file := models.File{
		Hash:        "ready-variant",
		Path:        "/uploads/ready-variant.jpg",
		MimeType:    "image/jpeg",
		AccessScope: models.FileAccessPublic,
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Exec(
		"INSERT INTO image_variants (file_id, variant, recipe_version, status, path, mime_type) VALUES (?, ?, ?, ?, ?, ?)",
		file.ID, "thumb", 1, "ready", "/uploads/ready-variant_v1_thumb.jpg", "image/jpeg",
	).Error; err != nil {
		t.Fatal(err)
	}
	diskPath := filepath.Join(uploadDir, "ready-variant_v1_thumb.jpg")
	if err := os.WriteFile(diskPath, []byte("ready variant"), 0o600); err != nil {
		t.Fatal(err)
	}
	handler := NewUploadHandler(uploadDir, 10<<20, db)
	router := gin.New()
	router.GET("/uploads/*filepath", handler.ServePublic)

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/uploads/ready-variant_v1_thumb.jpg", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("ready 变体响应=%d，body=%s", recorder.Code, recorder.Body.String())
	}
	if recorder.Header().Get("Content-Type") != "image/jpeg" {
		t.Fatalf("Content-Type=%q", recorder.Header().Get("Content-Type"))
	}
	if got := recorder.Header().Get("Cache-Control"); got != "public, max-age=86400, stale-while-revalidate=604800" {
		t.Fatalf("Cache-Control=%q", got)
	}
	if got := recorder.Body.String(); got != "ready variant" {
		t.Fatalf("变体内容=%q", got)
	}
}

func TestServePublicResolvesJPEGPreviewBackToGIFOrigin(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newUploadTestDB(t)
	uploadDir := t.TempDir()
	file := models.File{
		Hash:        "ready-gif-preview",
		Path:        "/uploads/ready-gif-preview.gif",
		MimeType:    "image/gif",
		AccessScope: models.FileAccessPublic,
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.ImageVariant{
		FileID: file.ID, Variant: "thumb", RecipeVersion: 1,
		Status: models.ImageVariantStatusReady,
		Path:   "/uploads/ready-gif-preview_v1_thumb.jpg", MimeType: "image/jpeg",
	}).Error; err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(uploadDir, "ready-gif-preview_v1_thumb.jpg"),
		[]byte("static gif preview"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}

	router := gin.New()
	router.GET("/uploads/*filepath", NewUploadHandler(uploadDir, 10<<20, db).ServePublic)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(
		recorder,
		httptest.NewRequest(http.MethodGet, "/uploads/ready-gif-preview_v1_thumb.jpg", nil),
	)
	if recorder.Code != http.StatusOK {
		t.Fatalf("GIF 静态变体响应=%d，body=%s", recorder.Code, recorder.Body.String())
	}
	if got := recorder.Header().Get("Content-Type"); got != "image/jpeg" {
		t.Fatalf("GIF 静态变体 Content-Type=%q", got)
	}
	if got := recorder.Body.String(); got != "static gif preview" {
		t.Fatalf("GIF 静态变体内容=%q", got)
	}
}

func TestServePublicLegacyVariantServesReadyCurrentVariantWithoutCache(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newUploadTestDB(t)
	uploadDir := t.TempDir()
	file := models.File{Hash: "legacy-variant", Path: "/uploads/legacy-variant.jpg", MimeType: "image/jpeg", AccessScope: models.FileAccessPublic}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Exec(
		"INSERT INTO image_variants (file_id, variant, recipe_version, status, path, mime_type) VALUES (?, ?, ?, ?, ?, ?)",
		file.ID, "thumb", 1, "ready", "/uploads/legacy-variant_v1_thumb.jpg", "image/jpeg",
	).Error; err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(uploadDir, "legacy-variant_v1_thumb.jpg"), []byte("ready legacy alias"), 0o600); err != nil {
		t.Fatal(err)
	}
	handler := NewUploadHandler(uploadDir, 10<<20, db)
	router := gin.New()
	router.GET("/uploads/*filepath", handler.ServePublic)

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, fmt.Sprintf("/uploads/%s", "legacy-variant_thumb.jpg"), nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("遗留变体响应=%d", recorder.Code)
	}
	if got := recorder.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("遗留变体 Cache-Control=%q", got)
	}
	if got := recorder.Body.String(); got != "ready legacy alias" {
		t.Fatalf("遗留变体内容=%q", got)
	}
}

func TestServePublicPrivateFileReturnsNoStore404(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newUploadTestDB(t)
	uploadDir := t.TempDir()
	file := models.File{Hash: "private-image", Path: "/uploads/private-image.jpg", MimeType: "image/jpeg", AccessScope: models.FileAccessPrivate}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(uploadDir, "private-image.jpg"), []byte("private"), 0o600); err != nil {
		t.Fatal(err)
	}
	router := gin.New()
	router.GET("/uploads/*filepath", NewUploadHandler(uploadDir, 10<<20, db).ServePublic)

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/uploads/private-image.jpg", nil))
	if recorder.Code != http.StatusNotFound {
		t.Fatalf("私有文件响应=%d", recorder.Code)
	}
	if got := recorder.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("私有文件 Cache-Control=%q", got)
	}
	if got := recorder.Header().Get("X-Accel-Redirect"); got != "" {
		t.Fatalf("私有文件不得设置 X-Accel-Redirect: %q", got)
	}
}

func TestServePublicPendingVariantReturnsNoStore404(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newUploadTestDB(t)
	uploadDir := t.TempDir()
	file := models.File{Hash: "pending-image", Path: "/uploads/pending-image.png", MimeType: "image/png", AccessScope: models.FileAccessPublic}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.ImageVariant{
		FileID: file.ID, Variant: "thumb", RecipeVersion: 1,
		Status: models.ImageVariantStatusPending, Path: "/uploads/pending-image_v1_thumb.png", MimeType: "image/png",
	}).Error; err != nil {
		t.Fatal(err)
	}
	router := gin.New()
	router.GET("/uploads/*filepath", NewUploadHandler(uploadDir, 10<<20, db).ServePublic)

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/uploads/pending-image_v1_thumb.png", nil))
	if recorder.Code != http.StatusNotFound || recorder.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("pending 变体响应=%d cache=%q", recorder.Code, recorder.Header().Get("Cache-Control"))
	}
}

func TestServePublicReadyVariantCanUseAccelRedirect(t *testing.T) {
	gin.SetMode(gin.TestMode)
	t.Setenv("UPLOAD_USE_ACCEL_REDIRECT", "true")
	t.Setenv("UPLOAD_ACCEL_PREFIX", "/_internal/uploads/")
	db := newUploadTestDB(t)
	uploadDir := t.TempDir()
	file := models.File{Hash: "accel-image", Path: "/uploads/accel-image.jpg", MimeType: "image/jpeg", AccessScope: models.FileAccessPublic}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.ImageVariant{
		FileID:  file.ID,
		Variant: "thumb", RecipeVersion: 1, Status: models.ImageVariantStatusReady,
		Path: "/uploads/accel-image_v1_thumb.jpg", MimeType: "image/jpeg",
	}).Error; err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(uploadDir, "accel-image_v1_thumb.jpg"), []byte("accel variant"), 0o600); err != nil {
		t.Fatal(err)
	}
	router := gin.New()
	router.GET("/uploads/*filepath", NewUploadHandler(uploadDir, 10<<20, db).ServePublic)

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/uploads/accel-image_v1_thumb.jpg", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("加速重定向响应=%d", recorder.Code)
	}
	if got := recorder.Header().Get("X-Accel-Redirect"); got != "/_internal/uploads/accel-image_v1_thumb.jpg" {
		t.Fatalf("X-Accel-Redirect=%q", got)
	}
	if recorder.Body.Len() != 0 {
		t.Fatalf("加速重定向不应写入响应体: %q", recorder.Body.String())
	}
}
