package handlers

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"testing"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
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
			Title        string   `json:"title"`
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
	// 核心契约断言：ranking_score 必须在 0~100 尺度，且精确对齐当前有效样本语义。
	// 有效样本可能包含诚信权重，因此测试从 handler 的聚合结果读取 n 与 C，避免把旧的
	// “原始评价条数/未加权全局均值”重新固化成测试契约。
	stats, err := handler.queryCanteenStats()
	if err != nil {
		t.Fatalf("query canteen stats: %v", err)
	}
	mean := globalMeanStars(stats)
	var statsA canteenStatsRow
	for _, row := range stats {
		if row.ID == canteenA.ID {
			statsA = row
			break
		}
	}
	expectedRawA := services.BayesianRatingScore(statsA.AverageStar, statsA.EffectiveSample, mean, services.BayesianPriorWeight)
	expectedScoreA := services.BayesianScoreTo100(expectedRawA)
	if math.Abs(homeMap.Hero.RankingScore-expectedScoreA) > 1e-6 {
		t.Fatalf("hero ranking_score=%f want exact %f", homeMap.Hero.RankingScore, expectedScoreA)
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
		if f.Type == "recommended_store" {
			// Title 仅为兼容字段，客户端不会把它当作店铺卡主标题。
			if f.Title != "综合推荐" {
				t.Fatalf("recommended_store title=%q want '综合推荐'", f.Title)
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
	if math.Abs(rankMap.Items[0].RankingScore-expectedScoreA) > 1e-6 {
		t.Fatalf("rank1 ranking_score=%f want exact %f", rankMap.Items[0].RankingScore, expectedScoreA)
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
	if math.Abs(listItems[0].RankingScore-expectedScoreA) > 1e-6 {
		t.Fatalf("list[0] ranking_score=%f want exact %f", listItems[0].RankingScore, expectedScoreA)
	}
}

// TestCanteenDiscoveryCacheInvalidation 验证实拍审核通过、下架以及菜品隐藏后，首页发现缓存必须立即失效。
func TestCanteenDiscoveryCacheInvalidation(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createCanteenTestUser(t, db, 1, "管理员")
	createCanteenTestUser(t, db, 10, "用户10")

	canteen := models.Canteen{Name: "清真餐厅", Image: "/uploads/halal.png", CreatedBy: 1, Verified: true}
	db.Create(&canteen)
	dish := models.CanteenDish{CanteenID: canteen.ID, Name: "大盘鸡", NormalizedName: "大盘鸡", Status: models.DishStatusActive}
	db.Create(&dish)

	file := models.File{Hash: "hash-dpj", Path: "/uploads/dpj.png", Size: 100, MimeType: "image/png"}
	db.Create(&file)

	photo := models.CanteenDishPhoto{
		DishID:    dish.ID,
		FileID:    file.ID,
		UserID:    10,
		Status:    models.DishPhotoStatusPending,
		SortOrder: 0,
	}
	db.Create(&photo)

	canteenHandler := NewCanteenHandler(db)
	photoAdminHandler := NewCanteenDishPhotoAdminHandler(db)

	hasRecentPhotoInHome := func() bool {
		resp := performCanteenRequest(t, canteenHandler.GetHome, http.MethodGet, "/api/canteens/home", nil, 0, "")
		if resp.Code != http.StatusOK {
			t.Fatalf("get home status=%d", resp.Code)
		}
		var h struct {
			Feed []struct {
				Type   string `json:"type"`
				DishID uint   `json:"dish_id"`
			} `json:"feed"`
		}
		if err := json.Unmarshal(resp.Body.Bytes(), &h); err != nil {
			t.Fatalf("unmarshal home: %v", err)
		}
		for _, f := range h.Feed {
			if f.Type == "recent_photo" && f.DishID == dish.ID {
				return true
			}
		}
		return false
	}

	// 1. 预热 /canteens/home 缓存（此时实拍处于 pending，首页无 recent_photo）
	canteenDiscoveryCache.Invalidate()
	if hasRecentPhotoInHome() {
		t.Fatalf("pending photo must not appear in home")
	}

	// 2. 管理员审核通过实拍 -> 缓存必须立即失效并出现实拍
	approveURL := fmt.Sprintf("/api/canteens/dish-photos/%d/approve", photo.ID)
	approveParams := gin.Params{gin.Param{Key: "photoId", Value: fmt.Sprintf("%d", photo.ID)}}
	respApprove := performCanteenRequest(t, photoAdminHandler.ApproveDishPhoto, http.MethodPost, approveURL, approveParams, 1, "")
	if respApprove.Code != http.StatusOK {
		t.Fatalf("approve status=%d body=%s", respApprove.Code, respApprove.Body.String())
	}
	if !hasRecentPhotoInHome() {
		t.Fatalf("after approve, home cache must be invalidated and immediately display the approved photo")
	}

	// 3. 预热首页缓存后，管理员下架实拍 -> 缓存必须立即失效且实拍立刻消失
	archiveURL := fmt.Sprintf("/api/canteens/dish-photos/%d/archive", photo.ID)
	archiveParams := gin.Params{gin.Param{Key: "photoId", Value: fmt.Sprintf("%d", photo.ID)}}
	respArchive := performCanteenRequest(t, photoAdminHandler.ArchiveDishPhoto, http.MethodPost, archiveURL, archiveParams, 1, "")
	if respArchive.Code != http.StatusOK {
		t.Fatalf("archive status=%d body=%s", respArchive.Code, respArchive.Body.String())
	}
	if hasRecentPhotoInHome() {
		t.Fatalf("after archive, home cache must be invalidated and photo must immediately disappear")
	}

	// 4. 新增一个已通过实拍，再次预热；然后将菜品设为 hidden -> 缓存必须立即失效且不再展示
	file2 := models.File{Hash: "hash-dpj-2", Path: "/uploads/dpj2.png", Size: 100, MimeType: "image/png"}
	db.Create(&file2)
	photo2 := models.CanteenDishPhoto{
		DishID:    dish.ID,
		FileID:    file2.ID,
		UserID:    10,
		Status:    models.DishPhotoStatusApproved,
		SortOrder: 0,
	}
	db.Create(&photo2)
	canteenDiscoveryCache.Invalidate()
	if !hasRecentPhotoInHome() {
		t.Fatalf("expected approved photo2 in home")
	}

	updateDishURL := fmt.Sprintf("/api/canteens/dishes/%d", dish.ID)
	updateDishParams := gin.Params{gin.Param{Key: "dishId", Value: fmt.Sprintf("%d", dish.ID)}}
	hiddenStatus := models.DishStatusHidden
	updateBody, _ := json.Marshal(map[string]any{"status": hiddenStatus})
	respUpdate := performCanteenRequest(t, photoAdminHandler.AdminUpdateDish, http.MethodPatch, updateDishURL, updateDishParams, 1, string(updateBody))
	if respUpdate.Code != http.StatusOK {
		t.Fatalf("update dish status=%d body=%s", respUpdate.Code, respUpdate.Body.String())
	}
	if hasRecentPhotoInHome() {
		t.Fatalf("after hiding dish, home cache must be invalidated and hidden dish photos must disappear")
	}
}
