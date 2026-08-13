package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"

	"shenliyuan/internal/models"
)

// TestCanteenBayesianRanking 验证 Bayesian 排序：
// 小样本 5.0 不直接榜首；无评价食堂置后。
func TestCanteenBayesianRanking(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createCanteenTestUser(t, db, 1, "管理员")
	createCanteenTestUser(t, db, 2, "A")
	createCanteenTestUser(t, db, 3, "B")
	createCanteenTestUser(t, db, 4, "C")

	// A：1 人评 5 星（小样本高分的陷阱案例）
	canteenA := models.Canteen{Name: "小样本满分", Image: "/uploads/a.png", CreatedBy: 1, Verified: true}
	db.Create(&canteenA)
	// B：50 人评 4.8（大样本稳定高分，每个用户一条评价）
	canteenB := models.Canteen{Name: "大样本稳定", Image: "/uploads/b.png", CreatedBy: 1, Verified: true}
	db.Create(&canteenB)
	// C：无评价
	canteenC := models.Canteen{Name: "无评价食堂", Image: "/uploads/c.png", CreatedBy: 1, Verified: true}
	db.Create(&canteenC)

	// A 的 1 条 5 星
	db.Create(&models.CanteenRating{CanteenID: canteenA.ID, UserID: 2, Star: 5})
	// B 的 50 条 4.8（50 个不同用户，4 和 5 交替逼近 4.8）
	stars := []int{5, 5, 5, 5, 4, 5, 5, 5, 5, 5}
	for i := 0; i < 50; i++ {
		userID := uint(100 + i)
		createCanteenTestUser(t, db, userID, fmt.Sprintf("user-%d", userID))
		db.Create(&models.CanteenRating{CanteenID: canteenB.ID, UserID: userID, Star: stars[i%10]})
	}

	handler := NewCanteenHandler(db)
	resp := performCanteenRequest(t, handler.GetList, http.MethodGet, "/api/canteens", nil, 0, "")
	if resp.Code != http.StatusOK {
		t.Fatalf("list status=%d body=%s", resp.Code, resp.Body.String())
	}
	var list []struct {
		Name        string  `json:"name"`
		AverageStar float64 `json:"average_star"`
		RatingCount int     `json:"rating_count"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &list); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(list) != 3 {
		t.Fatalf("list len=%d want 3", len(list))
	}

	// 断言：大样本稳定（B）应排在小样本满分（A）之前（Bayesian 拉低小样本）。
	if list[0].Name != "大样本稳定" {
		t.Fatalf("first=%q want 大样本稳定 (Bayesian 优先大样本): %s",
			list[0].Name, resp.Body.String())
	}
	// 断言：无评价食堂排最后。
	if list[2].Name != "无评价食堂" {
		t.Fatalf("last=%q want 无评价食堂 (unrated last)", list[2].Name)
	}
	// 断言：显示仍是真实平均分，不是 weighted_score。
	if list[0].AverageStar < 4.5 {
		t.Fatalf("displayed average=%f should be real average not weighted", list[0].AverageStar)
	}

	_ = fmt.Sprintf("%d", canteenC.ID)
}
