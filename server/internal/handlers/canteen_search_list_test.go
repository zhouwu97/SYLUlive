package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
	"time"

	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// seedSearchListCanteens 建立三家营业店和一家已下架店。创建时间与综合排名刻意相反，
// 用来证明结果顺序和名次来自综合排行，而不是按创建时间倒序的统计查询。
func seedSearchListCanteens(t *testing.T, db *gorm.DB) {
	t.Helper()
	createCanteenTestUser(t, db, 1, "提交者")
	base := time.Now().Add(-time.Hour)
	seed := func(name string, offset time.Duration, status string, stars ...int) models.Canteen {
		canteen := models.Canteen{
			Name: name, NormalizedName: name, Image: "/uploads/" + name + ".png", CreatedBy: 1,
			Verified: true, OperatingStatus: status, CreatedAt: base.Add(offset),
		}
		if err := db.Create(&canteen).Error; err != nil {
			t.Fatalf("create canteen %s: %v", name, err)
		}
		for i, star := range stars {
			userID := uint(canteen.ID*100 + uint(i) + 10)
			createCanteenTestUser(t, db, userID, fmt.Sprintf("u-%d", userID))
			if err := db.Create(&models.CanteenRating{CanteenID: canteen.ID, UserID: userID, Star: star}).Error; err != nil {
				t.Fatalf("create rating: %v", err)
			}
		}
		return canteen
	}
	seed("牛肉面", 0, models.CanteenOperatingActive, 5, 5, 5, 5)
	seed("黄焖鸡", time.Minute, models.CanteenOperatingActive, 4, 4, 4)
	seed("拉面", 2*time.Minute, models.CanteenOperatingActive, 2)
	seed("下架面馆", 3*time.Minute, models.CanteenOperatingOffline, 5)
}

func TestSearchReturnsCompositeRankNotResultIndex(t *testing.T) {
	db := newCanteenTestDB(t)
	seedSearchListCanteens(t, db)
	h := NewCanteenHandler(db)

	resp := performCanteenRequest(t, h.Search, http.MethodGet, "/api/canteens/search?q=面", nil, 0, "")
	if resp.Code != http.StatusOK {
		t.Fatalf("search status=%d body=%s", resp.Code, resp.Body.String())
	}
	var body struct {
		Canteens []struct {
			Name string `json:"name"`
			Rank int    `json:"rank"`
		} `json:"canteens"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	// 黄焖鸡不匹配却占综合第 2 名，拉面必须显示真实名次 3 而不是结果下标 2；下架店不出现。
	want := []struct {
		name string
		rank int
	}{{"牛肉面", 1}, {"拉面", 3}}
	if len(body.Canteens) != len(want) {
		t.Fatalf("canteens=%+v want %+v", body.Canteens, want)
	}
	for i, w := range want {
		if body.Canteens[i].Name != w.name || body.Canteens[i].Rank != w.rank {
			t.Fatalf("canteens[%d]=%+v want %+v", i, body.Canteens[i], w)
		}
	}
}

func decodeCanteenNames(t *testing.T, raw []byte) []string {
	t.Helper()
	var list []struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal(raw, &list); err != nil {
		t.Fatalf("decode list: %v body=%s", err, raw)
	}
	names := make([]string, 0, len(list))
	for _, item := range list {
		names = append(names, item.Name)
	}
	return names
}

func TestGetListFiltersByQueryStatusAndPaginates(t *testing.T) {
	db := newCanteenTestDB(t)
	seedSearchListCanteens(t, db)
	h := NewCanteenHandler(db)
	list := func(path string) (int, []string) {
		resp := performCanteenRequest(t, h.GetList, http.MethodGet, path, nil, 0, "")
		if resp.Code != http.StatusOK {
			return resp.Code, nil
		}
		return resp.Code, decodeCanteenNames(t, resp.Body.Bytes())
	}

	// 无参数保持旧行为：全部已审核食堂，含已下架（管理端依赖）。
	if _, names := list("/api/canteens"); len(names) != 4 {
		t.Fatalf("default list=%v want 4 items", names)
	}
	if _, names := list("/api/canteens?q=面"); fmt.Sprint(names) != "[牛肉面 拉面 下架面馆]" {
		t.Fatalf("q list=%v", names)
	}
	if _, names := list("/api/canteens?q=面&status=active"); fmt.Sprint(names) != "[牛肉面 拉面]" {
		t.Fatalf("active q list=%v", names)
	}
	if _, names := list("/api/canteens?status=active&limit=2&page=2"); fmt.Sprint(names) != "[拉面]" {
		t.Fatalf("page 2 list=%v", names)
	}
	if _, names := list("/api/canteens?status=active&limit=2&page=99999999999"); len(names) != 0 {
		t.Fatalf("far page list=%v want empty", names)
	}
	for _, path := range []string{"/api/canteens?limit=0", "/api/canteens?limit=101", "/api/canteens?limit=2&page=0", "/api/canteens?limit=x"} {
		if code, _ := list(path); code != http.StatusBadRequest {
			t.Fatalf("%s status=%d want 400", path, code)
		}
	}
}

// 搜“二食堂”能列出二食堂的店，搜“出餐快”能找到近期被这样评价的店；排行带完整标签 key 供筛选。
func TestSearchMatchesLocationAndTagsAndRankingExposesTagKeys(t *testing.T) {
	h, _, user := prepareReviewV2DB(t)
	second := models.Canteen{Name: "黄焖鸡", NormalizedName: "黄焖鸡", LocationArea: models.CanteenLocationArea2,
		LocationFloor: models.CanteenLocationFloor1, Image: "/uploads/h.png", CreatedBy: user.ID, Verified: true}
	if err := h.db.Create(&second).Error; err != nil {
		t.Fatal(err)
	}
	resp := performCanteenRequest(t, h.CreateReview, http.MethodPost, "/api/canteens/88/reviews", mapParams("id", "88"), user.ID,
		`{"taste_score":4,"value_score":4,"queue_score":4,"hygiene_score":4,"service_score":4,"tags":["serving_fast","clean","price_fair","good_value"]}`)
	if resp.Code != http.StatusCreated {
		t.Fatalf("review status=%d", resp.Code)
	}
	search := func(q string) []string {
		resp := performCanteenRequest(t, h.Search, http.MethodGet, "/api/canteens/search?q="+q, nil, 0, "")
		var body struct {
			Canteens []struct {
				Name string `json:"name"`
			} `json:"canteens"`
		}
		_ = json.Unmarshal(resp.Body.Bytes(), &body)
		names := []string{}
		for _, c := range body.Canteens {
			names = append(names, c.Name)
		}
		return names
	}
	if got := fmt.Sprint(search("二食堂")); got != "[黄焖鸡]" {
		t.Fatalf("location search=%s", got)
	}
	if got := fmt.Sprint(search("出餐快")); got != "[一食堂]" {
		t.Fatalf("tag search=%s", got)
	}

	ranking := performCanteenRequest(t, h.GetRankings, http.MethodGet, "/api/canteens/rankings", nil, 0, "")
	var body struct {
		Items []struct {
			Name        string        `json:"name"`
			SummaryTags []interface{} `json:"summary_tags"`
			TagKeys     []string      `json:"tag_keys"`
		} `json:"items"`
	}
	_ = json.Unmarshal(ranking.Body.Bytes(), &body)
	for _, item := range body.Items {
		if item.Name == "一食堂" && (len(item.TagKeys) != 4 || len(item.SummaryTags) != 3) {
			t.Fatalf("tag keys=%v summary=%d", item.TagKeys, len(item.SummaryTags))
		}
		if item.Name == "黄焖鸡" && (item.TagKeys == nil || len(item.TagKeys) != 0) {
			t.Fatalf("untagged shop must return empty tag_keys array, got %v", item.TagKeys)
		}
	}
}
