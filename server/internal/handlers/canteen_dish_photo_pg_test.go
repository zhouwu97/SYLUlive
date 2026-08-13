//go:build integration

package handlers

import (
	"fmt"
	"net/http"
	"os"
	"sync"
	"testing"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// TestDishPhotoConcurrentApproval 验证 PostgreSQL 下两个管理员同时 approve：
// 从 approved=2 开始，最终必须恰好 3，绝不允许 4。
// 需要 TEST_DATABASE_DSN。
func TestDishPhotoConcurrentApproval(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_DSN")
	if dsn == "" {
		t.Skip("TEST_DATABASE_DSN 未设置，跳过 PostgreSQL 并发集成测试")
	}
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	sqlDB, _ := db.DB()
	sqlDB.SetMaxOpenConns(20)

	// 隔离测试数据
	cleanup := func() {
		db.Exec("DELETE FROM canteen_dish_photos")
		db.Exec("DELETE FROM canteen_dishes")
		db.Exec("DELETE FROM canteen_ratings")
		db.Exec("DELETE FROM canteens")
		db.Exec("DELETE FROM users WHERE id > 1000")
		db.Exec("DELETE FROM files")
	}
	cleanup()
	t.Cleanup(cleanup)

	if err := db.AutoMigrate(&models.Canteen{}, &models.CanteenRating{}, &models.CanteenRatingVote{},
		&models.CanteenDish{}, &models.CanteenDishPhoto{}, &models.File{}, &models.User{}, &models.AdminLog{}); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if err := models.EnsureCanteenDishSchema(db); err != nil {
		t.Fatalf("ensure dish schema: %v", err)
	}

	// 数据：1 个食堂、1 道菜、3 个 approved + 2 个待审核实拍（供并发 approve）
	canteen := models.Canteen{Name: "并发食堂", Image: "/uploads/canteen.png", CreatedBy: 2001, Verified: true}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatalf("create canteen: %v", err)
	}
	dish := models.CanteenDish{CanteenID: canteen.ID, Name: "锅包肉", NormalizedName: "锅包肉", Status: models.DishStatusActive, CreatedBy: 2001}
	if err := db.Create(&dish).Error; err != nil {
		t.Fatalf("create dish: %v", err)
	}

	// 创建文件 + 实拍
	newPhoto := func(id uint, status string) models.CanteenDishPhoto {
		path := fmt.Sprintf("/uploads/pg-%d.jpg", id)
		file := models.File{ID: id, Hash: fmt.Sprintf("pg-hash-%d", id), Path: path,
			Size: 10, MimeType: "image/jpeg", UploaderID: 2001, Status: "active", AccessScope: models.FileAccessPrivate}
		if err := db.Create(&file).Error; err != nil {
			t.Fatalf("create file: %v", err)
		}
		photo := models.CanteenDishPhoto{DishID: dish.ID, FileID: id, UserID: 2001, Status: status}
		if err := db.Create(&photo).Error; err != nil {
			t.Fatalf("create photo: %v", err)
		}
		return photo
	}
	for i := 0; i < 3; i++ {
		newPhoto(uint(3000+i), models.DishPhotoStatusApproved)
	}
	pending1 := newPhoto(3010, models.DishPhotoStatusPending)
	pending2 := newPhoto(3011, models.DishPhotoStatusPending)

	// 管理员用户
	db.Create(&models.User{ID: 2001, StudentID: "admin-s", PasswordHash: "x", Nickname: "管理员"})

	adminHandler := NewCanteenDishPhotoAdminHandler(db)
	gin.SetMode(gin.TestMode)

	// 两个管理员并发 approve 两个 pending（从 approved=2 出发实际上限场景：
	// 为验证并发边界，先把 3 个 approved 中的 1 个删掉 → approved=2，再并发 approve 2 个 pending）。
	db.Exec("DELETE FROM canteen_dish_photos WHERE status = ? AND id = ?", models.DishPhotoStatusApproved, 3000)

	var wg sync.WaitGroup
	results := make([]int, 2)
	pendingIDs := []uint{pending1.ID, pending2.ID}
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			recorder := performDishPhotoRequest(t, adminHandler.ApproveDishPhoto, http.MethodPost,
				fmt.Sprintf("/api/canteens/dish-photos/%d/approve", pendingIDs[idx]),
				gin.Params{{Key: "photoId", Value: fmt.Sprint(pendingIDs[idx])}}, 2001, "")
			results[idx] = recorder.Code
		}(i)
	}
	wg.Wait()

	var approvedCount int64
	db.Model(&models.CanteenDishPhoto{}).
		Where("dish_id = ? AND status = ?", dish.ID, models.DishPhotoStatusApproved).
		Count(&approvedCount)
	if approvedCount != 3 {
		t.Fatalf("approved count=%d want exactly 3 (never 4); results=%v", approvedCount, results)
	}

	// 其中至少一个 409 gallery_full（因为上限 3）
	has409 := false
	for _, code := range results {
		if code == http.StatusConflict {
			has409 = true
		}
	}
	if !has409 {
		t.Fatalf("expected at least one 409 gallery_full among %v", results)
	}
}
