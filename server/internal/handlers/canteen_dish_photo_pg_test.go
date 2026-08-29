//go:build integration

package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)



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

	requireIntegrationTestDatabase(t, db)

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

// requireIntegrationTestDatabase 是破坏性集成测试的硬保护：这些测试会清空
// canteen_* / files / 部分 users 表，绝不能指向开发库或生产库。
// requireIntegrationTestDatabase 是破坏性集成测试的硬保护：这些测试会清空
// canteen_* / files / 部分 users 表，绝不能指向开发库或生产库。
// 双重校验：1) 必须显式设置 ALLOW_DESTRUCTIVE_INTEGRATION_TESTS=1（防止误跑）；
// 2) 当前数据库名必须以 _test 结尾（防止 test/prod 名称混淆）。
// 任一不满足即放弃本次测试，绝不执行任何清表。
func requireIntegrationTestDatabase(t *testing.T, db *gorm.DB) {
	t.Helper()
	if os.Getenv("ALLOW_DESTRUCTIVE_INTEGRATION_TESTS") != "1" {
		t.Skip("ALLOW_DESTRUCTIVE_INTEGRATION_TESTS 未显式开启，跳过破坏性集成测试")
	}
	var dbName string
	if err := db.Raw("SELECT current_database()").Scan(&dbName).Error; err != nil {
		t.Fatalf("read current_database: %v", err)
	}
	lower := strings.ToLower(dbName)
	if lower == "_test" || !strings.HasSuffix(lower, "_test") {
		t.Fatalf("refuse destructive integration test on database %q (name must end in _test)", dbName)
	}
}
