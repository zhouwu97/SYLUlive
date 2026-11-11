package handlers

import (
	"encoding/json"
	"net/http"
	"testing"
)

// 新增体验标签时必须同时加进 canteenTagOrder，否则客户端筛选里会悄悄少一个标签。
func TestGetMetaListsEveryReviewTagAndLocation(t *testing.T) {
	if len(canteenTagOrder) != len(validCanteenTags) {
		t.Fatalf("canteenTagOrder=%d validCanteenTags=%d", len(canteenTagOrder), len(validCanteenTags))
	}
	resp := performCanteenRequest(t, NewCanteenHandler(nil).GetMeta, http.MethodGet, "/api/canteens/meta", nil, 0, "")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d", resp.Code)
	}
	var body struct {
		Areas  []string `json:"location_areas"`
		Floors []string `json:"location_floors"`
		Tags   []struct {
			Key   string `json:"key"`
			Label string `json:"label"`
		} `json:"review_tags"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Areas) != 2 || len(body.Floors) != 2 || len(body.Tags) != len(validCanteenTags) {
		t.Fatalf("meta=%+v", body)
	}
	if body.Tags[0].Key != "taste_good" || body.Tags[0].Label != "味道不错" {
		t.Fatalf("first tag=%+v", body.Tags[0])
	}
}
