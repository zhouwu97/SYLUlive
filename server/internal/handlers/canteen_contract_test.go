package handlers

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"testing"

	"shenliyuan/internal/models"
)

// TestCanteenAPIContractJSON 验证真正的 HTTP Handler 返回的 JSON 契约：
// 1. ranking_score 必须是 0~100 尺度（例如 4.30 -> 86.0），绝不能把 1~5 原始分直接给前端。
// 2. average_star 保持真实 1~5 星级。
// 3. stable_choice 的 reason 必须是“评价样本相对更多，结果受单条评价影响更小”。
// 4. Rankings / Home / List 的 ranking_score 全线统一。
func TestCanteenAPIContractJSON(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createCanteenTestUser(t, db, 1, "管理员")

	// 食堂 A：5 人 4.6 星（按 m=5, C=4.0 计算 Bayesian 得分 4.30，换算 100 分制应为 86.0）
	canteenA := models.Canteen{Name: "川渝椒香", Image: "/uploads/a.png", CreatedBy: 1, Verified: true}
	db.Create(&canteenA)
	for i := 0; i < 5; i++ {
		uid := uint(200 + i)
		createCanteenTestUser(t, db, uid, fmt.Sprintf("u-%d", uid))
		star := 5
		if i == 0 || i == 1 {
			star = 4
		}
		tags := `["taste_good","portion_enough"]`
		db.Create(&models.CanteenRating{CanteenID: canteenA.ID, UserID: uid, Star: star, Tags: tags})
	}

	// 食堂 B：4 人 3.8 星（Bayesian ~3.911，换算 100 分制 ~78.22）
	canteenB := models.Canteen{Name: "二楼快餐", Image: "/uploads/b.png", CreatedBy: 1, Verified: true}
	db.Create(&canteenB)
	for i := 0; i < 4; i++ {
		uid := uint(300 + i)
		createCanteenTestUser(t, db, uid, fmt.Sprintf("u-%d", uid))
		star := 4
		if i == 3 {
			star = 3
		}
		db.Create(&models.CanteenRating{CanteenID: canteenB.ID, UserID: uid, Star: star})
	}

	// 食堂 C：无评价
	canteenC := models.Canteen{Name: "新收录店", Image: "/uploads/c.png", CreatedBy: 1, Verified: true}
	db.Create(&canteenC)

	handler := NewCanteenHandler(db)

	// ── 1. 验证 GET /canteens/home 契约 ──────────────────────────────
	canteenDiscoveryCache.Invalidate()
	respHome := performCanteenRequest(t, handler.GetHome, http.MethodGet, "/api/canteens/home", nil, 0, "")
	if respHome.Code != http.StatusOK {
		t.Fatalf("home status=%d body=%s", respHome.Code, respHome.Body.String())
	}
	var homeMap struct {
		Hero struct {
			CanteenID    uint    `json:"canteen_id"`
			CanteenName  string  `json:"canteen_name"`
			RankingScore float64 `json:"ranking_score"`
			AverageStar  float64 `json:"average_star"`
			RatingCount  int     `json:"rating_count"`
			Reason       string  `json:"reason"`
		} `json:"hero"`
		RankingEntry struct {
			Top struct {
				ID           uint    `json:"id"`
				Name         string  `json:"name"`
				RankingScore float64 `json:"ranking_score"`
			} `json:"top"`
			Total int `json:"total"`
		} `json:"ranking_entry"`
		Feed []struct {
			ID           string   `json:"id"`
			Type         string   `json:"type"`
			CanteenID    uint     `json:"canteen_id"`
			RankingScore float64  `json:"ranking_score"`
			AverageStar  float64  `json:"average_star"`
			RatingCount  int      `json:"rating_count"`
			Reason       string   `json:"reason"`
			Tags         []string `json:"tags"`
		} `json:"feed"`
	}
	if err := json.Unmarshal(respHome.Body.Bytes(), &homeMap); err != nil {
		t.Fatalf("decode home JSON: %v", err)
	}

	// Hero 契约断言：
	if homeMap.Hero.CanteenID != canteenA.ID {
		t.Fatalf("hero id=%d want %d", homeMap.Hero.CanteenID, canteenA.ID)
	}
	// 核心契约断言：ranking_score 必须在 0~100 尺度（80~90 之间），绝不能是 4.30！
	if homeMap.Hero.RankingScore < 50.0 || homeMap.Hero.RankingScore > 100.0 {
		t.Fatalf("hero ranking_score=%f 违背 0~100 契约（疑似仍为 1~5 原始分或溢出）", homeMap.Hero.RankingScore)
	}
	if math.Abs(homeMap.Hero.RankingScore-86.0) > 2.0 {
		t.Fatalf("hero ranking_score=%f want ~86.0", homeMap.Hero.RankingScore)
	}
	if homeMap.Hero.AverageStar < 4.0 || homeMap.Hero.AverageStar > 5.0 {
		t.Fatalf("hero average_star=%f want 4.6", homeMap.Hero.AverageStar)
	}

	// 排行入口 Top1 契约断言：
	if homeMap.RankingEntry.Top.RankingScore < 50.0 {
		t.Fatalf("ranking_entry top ranking_score=%f 违背 0~100 契约", homeMap.RankingEntry.Top.RankingScore)
	}

	// Feed 契约断言：
	for _, f := range homeMap.Feed {
		if f.RankingScore > 0 && (f.RankingScore < 50.0 || f.RankingScore > 100.0) {
			t.Fatalf("feed item %s ranking_score=%f 违背 0~100 契约", f.ID, f.RankingScore)
		}
		if f.Type == "stable_choice" {
			wantReason := "评价样本相对更多，结果受单条评价影响更小"
			if f.Reason != wantReason {
				t.Fatalf("stable_choice reason=%q want %q", f.Reason, wantReason)
			}
		}
	}

	// ── 2. 验证 GET /canteens/rankings 契约 ──────────────────────────
	canteenDiscoveryCache.Invalidate()
	respRank := performCanteenRequest(t, handler.GetRankings, http.MethodGet, "/api/canteens/rankings?sort=composite", nil, 0, "")
	if respRank.Code != http.StatusOK {
		t.Fatalf("rankings status=%d body=%s", respRank.Code, respRank.Body.String())
	}
	var rankMap struct {
		Items []struct {
			Rank         int     `json:"rank"`
			ID           uint    `json:"id"`
			Name         string  `json:"name"`
			RankingScore float64 `json:"ranking_score"`
			AverageStar  float64 `json:"average_star"`
			RatingCount  int     `json:"rating_count"`
		} `json:"items"`
	}
	if err := json.Unmarshal(respRank.Body.Bytes(), &rankMap); err != nil {
		t.Fatalf("decode rankings JSON: %v", err)
	}
	if len(rankMap.Items) != 3 {
		t.Fatalf("items len=%d want 3", len(rankMap.Items))
	}
	// Rank 1（食堂 A）
	if rankMap.Items[0].Rank != 1 || rankMap.Items[0].ID != canteenA.ID {
		t.Fatalf("rank1 item=%+v want canteenA", rankMap.Items[0])
	}
	if rankMap.Items[0].RankingScore < 50.0 || rankMap.Items[0].RankingScore > 100.0 {
		t.Fatalf("rank1 ranking_score=%f 违背 0~100 契约", rankMap.Items[0].RankingScore)
	}

	// ── 3. 验证 GET /canteens 契约 ───────────────────────────────────
	respList := performCanteenRequest(t, handler.GetList, http.MethodGet, "/api/canteens", nil, 0, "")
	if respList.Code != http.StatusOK {
		t.Fatalf("list status=%d body=%s", respList.Code, respList.Body.String())
	}
	var listItems []struct {
		ID           uint    `json:"id"`
		Name         string  `json:"name"`
		RankingScore float64 `json:"ranking_score"`
		AverageStar  float64 `json:"average_star"`
	}
	if err := json.Unmarshal(respList.Body.Bytes(), &listItems); err != nil {
		t.Fatalf("decode list JSON: %v", err)
	}
	if listItems[0].RankingScore < 50.0 || listItems[0].RankingScore > 100.0 {
		t.Fatalf("list[0] ranking_score=%f 违背 0~100 契约", listItems[0].RankingScore)
	}
}
