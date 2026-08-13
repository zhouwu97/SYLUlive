package handlers

import (
	"fmt"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/models"
)

// TestCanteenRateConcurrentNoDuplicates 并发调用 Rate 同一 (canteen,user)：
// 原子 upsert 下最终仅一条评价，且全部返回 200。
func TestCanteenRateConcurrentNoDuplicates(t *testing.T) {
	db := newCanteenTestDB(t)
	// SQLite in-memory 需要单连接串行化写，避免 database is locked。
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get sql db: %v", err)
	}
	sqlDB.SetMaxOpenConns(1)
	createCanteenTestUser(t, db, 1, "提交者")
	canteen := models.Canteen{Name: "并发测试食堂", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatalf("create canteen: %v", err)
	}
	verifiedAt := time.Now()
	if err := db.Model(&models.User{}).Where("id = ?", 1).Updates(map[string]interface{}{
		"student_verified_at": verifiedAt,
		"edu_authorized":      true,
		"edu_bound":           true,
	}).Error; err != nil {
		t.Fatalf("bind edu: %v", err)
	}
	handler := NewCanteenHandler(db)

	const goroutines = 10
	var wg sync.WaitGroup
	statusCodes := make([]int, goroutines)
	for i := 0; i < goroutines; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			resp := performCanteenRequest(
				t,
				handler.Rate,
				http.MethodPost,
				fmt.Sprintf("/api/canteens/%d/rate", canteen.ID),
				gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
				1,
				`{"star":5,"comment":"并发评价"}`,
			)
			statusCodes[idx] = resp.Code
		}(i)
	}
	wg.Wait()

	for i, code := range statusCodes {
		if code != http.StatusOK {
			t.Fatalf("goroutine %d status=%d want 200", i, code)
		}
	}

	var count int64
	db.Model(&models.CanteenRating{}).
		Where("canteen_id = ? AND user_id = ?", canteen.ID, 1).
		Count(&count)
	if count != 1 {
		t.Fatalf("ratings count=%d want 1", count)
	}

	var rating models.CanteenRating
	if err := db.Where("canteen_id = ? AND user_id = ?", canteen.ID, 1).First(&rating).Error; err != nil {
		t.Fatalf("get rating: %v", err)
	}
	if rating.Star != 5 {
		t.Fatalf("star=%d want 5", rating.Star)
	}
}
