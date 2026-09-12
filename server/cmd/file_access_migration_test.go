package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"shenliyuan/internal/handlers"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func TestStartupPreservesApprovedDishPublicImage(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "startup.db")), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	t.Cleanup(func() { _ = sqlDB.Close() })
	// 公开引用校验会联接菜品和食堂表，测试库需与生产查询的最小 schema 对齐。
	require.NoError(t, db.AutoMigrate(
		&models.File{}, &models.ImageVariant{}, &models.CanteenDishPhoto{},
		&models.CanteenDish{}, &models.Canteen{},
	))
	require.NoError(t, db.Exec("CREATE TABLE reports (reporter_id BIGINT, target_type TEXT, target_id BIGINT, status TEXT)").Error)
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "dish.jpg"), []byte("image-content"), 0600))
	file := models.File{Hash: "dish", Path: "/uploads/dish.jpg", MimeType: "image/jpeg", Status: "active", AccessScope: models.FileAccessPrivate}
	require.NoError(t, db.Create(&file).Error)
	require.NoError(t, db.Create(&models.Canteen{ID: 1, Name: "测试食堂", NormalizedName: "测试食堂", Verified: true}).Error)
	require.NoError(t, db.Create(&models.CanteenDish{ID: 1, CanteenID: 1, Name: "测试菜", NormalizedName: "测试菜", Status: models.DishStatusActive}).Error)
	require.NoError(t, db.Create(&models.CanteenDishPhoto{DishID: 1, FileID: file.ID, Status: models.DishPhotoStatusApproved}).Error)
	require.NoError(t, services.ClaimPublicImageFiles(db, []uint{file.ID}))
	router := gin.New()
	router.GET("/uploads/*filepath", handlers.NewUploadHandler(dir, 10<<20, db).ServePublic)
	for i := 0; i < 2; i++ {
		require.NoError(t, ensureSecurityHardeningSchema(db))
		require.NoError(t, db.First(&file, file.ID).Error)
		require.Equal(t, models.FileAccessPublic, file.AccessScope)
		response := httptest.NewRecorder()
		router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/uploads/dish.jpg", nil))
		require.Equal(t, http.StatusOK, response.Code)
	}
}
