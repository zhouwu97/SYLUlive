//go:build integration

package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sync"
	"testing"
	"time"

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

// TestDishPhotoConcurrentSameNameCreation 验证 PostgreSQL 下两个学生并发
// 对同一食堂投稿同一个归一化菜名：
// - 两请求都不能 500（不允许 unique error 后继续失败事务）
// - 最终 CanteenDish 恰好 1 行（ON CONFLICT DO NOTHING 复用）
// - 两个 pending 实拍都落库
// 需要 TEST_DATABASE_DSN。
func TestDishPhotoConcurrentSameNameCreation(t *testing.T) {
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

	canteen := models.Canteen{Name: "并发食堂", Image: "/uploads/canteen.png", CreatedBy: 2002, Verified: true}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatalf("create canteen: %v", err)
	}

	// 两个学生 + 各自的图片文件
	for _, uid := range []uint{2002, 2003} {
		if err := db.Create(&models.User{ID: uid, StudentID: fmt.Sprintf("stu-%d", uid),
			PasswordHash: "x", Nickname: fmt.Sprintf("学生%d", uid)}).Error; err != nil {
			t.Fatalf("create user: %v", err)
		}
		if err := db.Model(&models.User{}).Where("id = ?", uid).Updates(map[string]interface{}{
			"student_verified_at": time.Now(),
			"edu_authorized":      true,
			"edu_bound":           true,
		}).Error; err != nil {
			t.Fatalf("verify user: %v", err)
		}
	}
	for i, uid := range []uint{2002, 2003} {
		path := fmt.Sprintf("/uploads/pg-name-%d.jpg", uid)
		file := models.File{ID: uint(4000 + i), Hash: fmt.Sprintf("pg-name-hash-%d", i), Path: path,
			Size: 10, MimeType: "image/jpeg", UploaderID: uid, Status: "active", AccessScope: models.FileAccessPrivate}
		if err := db.Create(&file).Error; err != nil {
			t.Fatalf("create file: %v", err)
		}
	}

	handler := NewCanteenDishPhotoHandler(db)
	gin.SetMode(gin.TestMode)

	var wg sync.WaitGroup
	results := make([]int, 2)
	userIDs := []uint{2002, 2003}
	fileIDs := []uint{4000, 4001}
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			body := fmt.Sprintf(`{"dish_name":"  锅包肉 ","file_id":%d}`, fileIDs[idx])
			recorder := performDishPhotoRequest(t, handler.SubmitDishPhoto, http.MethodPost,
				fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
				gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}}, userIDs[idx], body)
			results[idx] = recorder.Code
		}(i)
	}
	wg.Wait()

	for i, code := range results {
		if code == http.StatusInternalServerError {
			t.Fatalf("request %d got 500 (PG failed-tx after unique conflict); body result=%v", i, results)
		}
		if code != http.StatusCreated {
			t.Fatalf("request %d status=%d want 201; results=%v", i, code, results)
		}
	}

	var dishCount int64
	if err := db.Model(&models.CanteenDish{}).
		Where("canteen_id = ? AND normalized_name = ?", canteen.ID, "锅包肉").
		Count(&dishCount).Error; err != nil {
		t.Fatalf("count dish: %v", err)
	}
	if dishCount != 1 {
		t.Fatalf("dish count=%d want exactly 1 (no duplicate rows)", dishCount)
	}

	var approvedCount int64
	if err := db.Model(&models.CanteenDishPhoto{}).
		Where("status = ?", models.DishPhotoStatusApproved).
		Count(&approvedCount).Error; err != nil {
		t.Fatalf("count approved: %v", err)
	}
	if approvedCount != 2 {
		t.Fatalf("approved count=%d want 2 (both submissions approved)", approvedCount)
	}
}

// TestCanteenRateConcurrentOptimisticLock 验证 PostgreSQL 行锁下两个带同一
// base_updated_at 的并发评价请求：严格恰好 1×200 + 1×409。
// SQLite 无真实行锁，无法保证该语义，因此只在 TEST_DATABASE_DSN 配置时运行。
// 需要 TEST_DATABASE_DSN。
func TestCanteenRateConcurrentOptimisticLock(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_DSN")
	if dsn == "" {
		t.Skip("TEST_DATABASE_DSN 未设置，跳过 PostgreSQL 并发积分锁集成测试")
	}
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	sqlDB, _ := db.DB()
	sqlDB.SetMaxOpenConns(20)

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

	// 已绑定教务的学生
	now := time.Now()
	user := models.User{ID: 3001, StudentID: "stu-3001", PasswordHash: "x",
		Nickname: "并发评价学生", StudentVerifiedAt: &now, EduBound: true}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	canteen := models.Canteen{Name: "并发评价食堂", Verified: true, CreatedBy: 1}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatalf("create canteen: %v", err)
	}

	handler := NewCanteenHandler(db)

	// 1. 初始化创建一条评价，作为并发修改的 base_updated_at
	initBody := `{"star": 5, "comment": "初始评价", "tags": ["clean"]}`
	wInit := performCanteenRequest(t, handler.Rate, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/rate", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprintf("%d", canteen.ID)}}, user.ID, initBody)
	if wInit.Code != http.StatusOK {
		t.Fatalf("初始化评价失败: %d %s", wInit.Code, wInit.Body.String())
	}
	var initResp struct {
		Rating models.CanteenRating `json:"rating"`
	}
	if err := json.Unmarshal(wInit.Body.Bytes(), &initResp); err != nil {
		t.Fatal(err)
	}
	baseTime := initResp.Rating.UpdatedAt.Format(time.RFC3339Nano)

	// 2. 两个 goroutine 带同一个 base_updated_at 同时提交修改
	var wg sync.WaitGroup
	results := make([]int, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			body := fmt.Sprintf(`{"star": %d, "comment": "并发修改%d", "base_updated_at": "%s"}`, idx+3, idx, baseTime)
			w := performCanteenRequest(t, handler.Rate, http.MethodPost,
				fmt.Sprintf("/api/canteens/%d/rate", canteen.ID),
				gin.Params{{Key: "id", Value: fmt.Sprintf("%d", canteen.ID)}}, user.ID, body)
			results[idx] = w.Code
		}(i)
	}
	wg.Wait()

	okCount, conflictCount := 0, 0
	for _, code := range results {
		if code == http.StatusOK {
			okCount++
		} else if code == http.StatusConflict {
			conflictCount++
		}
	}
	if okCount != 1 || conflictCount != 1 {
		t.Fatalf("并发乐观锁断言失败: okCount=%d, conflictCount=%d, results=%v", okCount, conflictCount, results)
	}
}
