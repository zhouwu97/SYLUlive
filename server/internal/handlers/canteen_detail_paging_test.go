package handlers

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"testing"

	"shenliyuan/internal/models"
)

func seedDetailReviews(t *testing.T, h *CanteenHandler, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		u := createVerifiedUser(t, h.db, uint(700+i), fmt.Sprintf("评价者%d", i))
		taste := 1 + i%5
		resp := performCanteenRequest(t, h.CreateReview, http.MethodPost, "/api/canteens/88/reviews", mapParams("id", "88"), u.ID,
			fmt.Sprintf(`{"taste_score":%d,"value_score":%d,"queue_score":%d,"hygiene_score":%d,"service_score":%d,"comment":"第%d条"}`, taste, taste, taste, taste, taste, i))
		if resp.Code != http.StatusCreated {
			t.Fatalf("seed review %d status=%d body=%s", i, resp.Code, resp.Body.String())
		}
	}
	// 一条旧版评分，确认混合流仍包含 legacy 数据。
	legacyUser := createVerifiedUser(t, h.db, 799, "老用户")
	if err := h.db.Create(&models.CanteenRating{CanteenID: 88, UserID: legacyUser.ID, Star: 5, Comment: "旧版好评", Status: "active"}).Error; err != nil {
		t.Fatal(err)
	}
}

func TestDetailCompactReturnsFirstPageOnly(t *testing.T) {
	h, _, _ := prepareReviewV2DB(t)
	seedDetailReviews(t, h, 7)

	full := performCanteenRequest(t, h.GetDetail, http.MethodGet, "/api/canteens/88", mapParams("id", "88"), 0, "")
	var fullBody map[string]interface{}
	_ = json.Unmarshal(full.Body.Bytes(), &fullBody)
	if len(fullBody["display_reviews"].([]interface{})) != 8 || len(fullBody["reviews"].([]interface{})) != 7 {
		t.Fatalf("full mode must keep old payload: display=%d reviews=%d",
			len(fullBody["display_reviews"].([]interface{})), len(fullBody["reviews"].([]interface{})))
	}

	compact := performCanteenRequest(t, h.GetDetail, http.MethodGet, "/api/canteens/88?compact=1&review_limit=3", mapParams("id", "88"), 0, "")
	if compact.Code != http.StatusOK {
		t.Fatalf("compact status=%d body=%s", compact.Code, compact.Body.String())
	}
	var body map[string]interface{}
	_ = json.Unmarshal(compact.Body.Bytes(), &body)
	if len(body["display_reviews"].([]interface{})) != 3 || body["display_reviews_total"].(float64) != 8 ||
		body["display_reviews_has_more"] != true {
		t.Fatalf("compact page=%v total=%v has_more=%v", len(body["display_reviews"].([]interface{})), body["display_reviews_total"], body["display_reviews_has_more"])
	}
	if len(body["reviews"].([]interface{})) != 0 || len(body["ratings"].([]interface{})) != 0 {
		t.Fatalf("compact mode should not resend legacy lists")
	}
	// 摘要只统计这一家店，结果必须和全量统计一致。
	// 时间衰减让两次请求之间的平均分有极小差异，用容差比较。
	if body["rating_count"] != fullBody["rating_count"] ||
		math.Abs(body["average_star"].(float64)-fullBody["average_star"].(float64)) > 1e-6 ||
		body["visit_review_count"] != fullBody["visit_review_count"] {
		t.Fatalf("compact stats differ: %v/%v/%v vs %v/%v/%v", body["rating_count"], body["average_star"], body["visit_review_count"],
			fullBody["rating_count"], fullBody["average_star"], fullBody["visit_review_count"])
	}
}

func TestDisplayReviewsPagingMatchesFullOrder(t *testing.T) {
	h, _, _ := prepareReviewV2DB(t)
	seedDetailReviews(t, h, 7)
	fetch := func(query string) map[string]interface{} {
		resp := performCanteenRequest(t, h.GetDisplayReviews, http.MethodGet, "/api/canteens/88/display-reviews"+query, mapParams("id", "88"), 0, "")
		if resp.Code != http.StatusOK {
			t.Fatalf("%s status=%d body=%s", query, resp.Code, resp.Body.String())
		}
		var body map[string]interface{}
		_ = json.Unmarshal(resp.Body.Bytes(), &body)
		return body
	}
	ids := func(items []interface{}) []string {
		out := make([]string, 0, len(items))
		for _, item := range items {
			m := item.(map[string]interface{})
			out = append(out, fmt.Sprintf("%v:%v", m["source"], m["id"]))
		}
		return out
	}
	all := ids(fetch("?sort=latest&limit=50")["items"].([]interface{}))
	if len(all) != 8 {
		t.Fatalf("all=%v", all)
	}
	first := fetch("?sort=latest&limit=5")
	second := fetch("?sort=latest&limit=5&offset=5")
	if first["has_more"] != true || second["has_more"] != false || second["next_offset"].(float64) != 8 {
		t.Fatalf("paging flags first=%v second=%v", first["has_more"], second["has_more"])
	}
	joined := append(ids(first["items"].([]interface{})), ids(second["items"].([]interface{}))...)
	if fmt.Sprint(joined) != fmt.Sprint(all) {
		t.Fatalf("paged order %v != full order %v", joined, all)
	}
	low := fetch("?filter=low&limit=50")
	if low["total"].(float64) != 4 { // taste 1、2 各两人（共 7 人：1,2,3,4,5,1,2）
		t.Fatalf("low filter total=%v", low["total"])
	}
	if code := performCanteenRequest(t, h.GetDisplayReviews, http.MethodGet, "/x?limit=0", mapParams("id", "88"), 0, "").Code; code != http.StatusBadRequest {
		t.Fatalf("limit=0 status=%d", code)
	}
	if code := performCanteenRequest(t, h.GetDisplayReviews, http.MethodGet, "/x", mapParams("id", "999"), 0, "").Code; code != http.StatusNotFound {
		t.Fatalf("missing canteen status=%d", code)
	}
}
