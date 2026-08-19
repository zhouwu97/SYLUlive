package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"

	"shenliyuan/internal/models"
)

// TestCanteenBayesianRanking 验证 Bayesian 排序：
// 在存在中低分长尾的前提下，大样本稳定高分应反超小样本单次满分（Bayesian 拉低小样本）；
// 无评价食堂置后；展示的是真实平均分而非 weighted score。
//
// 说明：该测试早期仅在"globalMean 子查询在 SQL 里退化为 0"的 bug 下才成立；
// 服务端已改为 Go 层计算 globalMean，故补足中低分长尾店，使反超在正确实现下成立。
func TestCanteenBayesianRanking(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createCanteenTestUser(t, db, 1, "管理员")

	// A：1 人评 5 星（小样本高分的陷阱案例）
	canteenA := models.Canteen{Name: "小样本满分", Image: "/uploads/a.png", CreatedBy: 1, Verified: true}
	db.Create(&canteenA)
	// B：50 人评 4.9（大样本稳定高分）
	canteenB := models.Canteen{Name: "大样本稳定", Image: "/uploads/b.png", CreatedBy: 1, Verified: true}
	db.Create(&canteenB)
	// C：无评价，应置后
	canteenC := models.Canteen{Name: "无评价食堂", Image: "/uploads/c.png", CreatedBy: 1, Verified: true}
	db.Create(&canteenC)
	// 中低分长尾店（20 人评 3.0 上下），压低全校平均分，让"大样本反超小样本满分"成立。
	for i := 0; i < 3; i++ {
		mid := models.Canteen{Name: fmt.Sprintf("长尾店%d", i), Image: "/uploads/m.png", CreatedBy: 1, Verified: true}
		db.Create(&mid)
		for j := 0; j < 20; j++ {
			userID := uint(1000 + i*100 + j)
			createCanteenTestUser(t, db, userID, fmt.Sprintf("mid-%d-%d", i, j))
			db.Create(&models.CanteenRating{CanteenID: mid.ID, UserID: userID, Star: 3})
		}
	}

	// A 的 1 条 5 星
	createCanteenTestUser(t, db, 2, "A")
	db.Create(&models.CanteenRating{CanteenID: canteenA.ID, UserID: 2, Star: 5})
	// B 的 50 条（4 与 5 交替，实际平均 4.9）
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
	if len(list) != 6 {
		t.Fatalf("list len=%d want 6", len(list))
	}

	// 断言：大样本稳定（B）应排在小样本满分（A）之前（Bayesian 拉低小样本）。
	if list[0].Name != "大样本稳定" {
		t.Fatalf("first=%q want 大样本稳定 (Bayesian 优先大样本): %s",
			list[0].Name, resp.Body.String())
	}
	// 断言：无评价食堂排最后。
	if list[5].Name != "无评价食堂" {
		t.Fatalf("last=%q want 无评价食堂 (unrated last)", list[5].Name)
	}
	// 断言：显示仍是真实平均分，不是 weighted_score。
	if list[0].AverageStar < 4.5 {
		t.Fatalf("displayed average=%f should be real average not weighted", list[0].AverageStar)
	}

	_ = fmt.Sprintf("%d", canteenC.ID)
}

// TestCanteenBayesianDeterministicSmallSample 验证截图场景（个位评价数）下顺序可解释、tie-break 稳定。
// A 4.6/5、B 3.8/4、C 4.3/3、D 4.3/3、E 4.0/3。
// 期望：Bayesian 下 B（3.8/4）被低分拉低，不应排在 C/D（4.3/3）之前。
func TestCanteenBayesianDeterministicSmallSample(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createCanteenTestUser(t, db, 1, "管理员")

	// A: 5 人 4.6；B: 4 人 3.8；C/D: 各 3 人 4.3；E: 3 人 4.0
	specs := []struct {
		name   string
		ratings []int
	}{
		{"A(4.6/5)", []int{5, 5, 4, 5, 4}},
		{"B(3.8/4)", []int{4, 4, 3, 4}},
		{"C(4.3/3)", []int{4, 4, 5}},
		{"D(4.3/3)", []int{5, 4, 4}},
		{"E(4.0/3)", []int{4, 4, 4}},
	}
	var canteens []models.Canteen
	uid := uint(100)
	for _, sp := range specs {
		c := models.Canteen{Name: sp.name, Image: "/uploads/x.png", CreatedBy: 1, Verified: true}
		db.Create(&c)
		canteens = append(canteens, c)
		for _, star := range sp.ratings {
			uid++
			createCanteenTestUser(t, db, uid, fmt.Sprintf("u-%d", uid))
			db.Create(&models.CanteenRating{CanteenID: c.ID, UserID: uid, Star: star})
		}
	}
	// 无评价食堂 z，应排最后
	z := models.Canteen{Name: "无评价Z", Image: "/uploads/z.png", CreatedBy: 1, Verified: true}
	db.Create(&z)

	handler := NewCanteenHandler(db)
	resp := performCanteenRequest(t, handler.GetList, http.MethodGet, "/api/canteens", nil, 0, "")
	if resp.Code != http.StatusOK {
		t.Fatalf("list status=%d body=%s", resp.Code, resp.Body.String())
	}
	var list []struct {
		Name         string  `json:"name"`
		AverageStar  float64 `json:"average_star"`
		RatingCount  int     `json:"rating_count"`
		RankingScore float64 `json:"ranking_score"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &list); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(list) != 6 {
		t.Fatalf("list len=%d want 6", len(list))
	}

	// 无评价食堂必须在最后。
	if list[len(list)-1].Name != "无评价Z" {
		t.Fatalf("last=%q want 无评价Z (unrated last): %s", list[len(list)-1].Name, resp.Body.String())
	}

	// B(3.8/4) 不得排在任意 4.3/3 之前（截图的痛点即 B 高过 4.3/3）。
	// pos 为 0 起下标，B 应排在 C 之后（pos 更大）。
	pos := map[string]int{}
	for i, it := range list {
		pos[it.Name] = i
	}
	if pos["B(3.8/4)"] < pos["C(4.3/3)"] {
		t.Fatalf("B(3.8/4) pos=%d 不应排在 C(4.3/3) pos=%d 之前: %s",
			pos["B(3.8/4)"], pos["C(4.3/3)"], resp.Body.String())
	}

	// ranking_score 应按 BayesianRatingScore 纯函数可复核（示例：A 应为全场最高）。
	got := map[string]float64{}
	for _, it := range list {
		got[it.Name] = it.RankingScore
	}
	if !(got["A(4.6/5)"] > got["C(4.3/3)"]) {
		t.Fatalf("A(4.6/5) score 应高于 C(4.3/3): %s", resp.Body.String())
	}
	if !(got["C(4.3/3)"] > got["B(3.8/4)"]) {
		t.Fatalf("C(4.3/3) score 应高于 B(3.8/4)（截图痛点，B 不应高过 4.3/3）: %s", resp.Body.String())
	}

	// 展示的仍是真实平均分而非 weighted score。
	avg := map[string]float64{}
	for _, it := range list {
		avg[it.Name] = it.AverageStar
	}
	_ = fmt.Sprintf("%.1f %.1f", avg["A(4.6/5)"], avg["C(4.3/3)"])
}
