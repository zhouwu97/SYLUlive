package handlers

import (
	"encoding/json"
	"net/http"
	"testing"

	"shenliyuan/internal/models"
)

// A13 的 HTTP 侧契约：分页字段必须真的出现在 /api/polls 的响应里，
// 而不是只存在于服务层结构体中。
// pollHTTPRecommendPoolSize 与 services.pollRecommendPoolSize 一致，
// 这里是 HTTP 契约侧的期望值：改池大小必须同时改服务端常量和这一处，测试会抓住不同步。
const pollHTTPRecommendPoolSize = 500

func decodePollListResponse(t *testing.T, body []byte) map[string]interface{} {
	t.Helper()
	var payload map[string]interface{}
	if err := json.Unmarshal(body, &payload); err != nil {
		t.Fatalf("投票列表响应不是 JSON 对象：%s", body)
	}
	for _, key := range []string{"items", "page", "limit", "total", "matched_total", "pool_size", "has_more"} {
		if _, ok := payload[key]; !ok {
			t.Fatalf("投票列表响应缺少 %q 字段：%s", key, body)
		}
	}
	return payload
}

func pollListInt64(t *testing.T, payload map[string]interface{}, key string) int64 {
	t.Helper()
	value, ok := payload[key].(float64)
	if !ok {
		t.Fatalf("%q 不是数字：%v", key, payload[key])
	}
	return int64(value)
}

func pollListBool(t *testing.T, payload map[string]interface{}, key string) bool {
	t.Helper()
	value, ok := payload[key].(bool)
	if !ok {
		t.Fatalf("%q 不是布尔值：%v", key, payload[key])
	}
	return value
}

func pollListIDs(payload map[string]interface{}) []uint {
	raw, _ := payload["items"].([]interface{})
	ids := make([]uint, 0, len(raw))
	for _, item := range raw {
		post, _ := item.(map[string]interface{})
		id, _ := post["id"].(float64)
		ids = append(ids, uint(id))
	}
	return ids
}

func TestPollListHTTPCarriesPaginationContract(t *testing.T) {
	db, author, _ := newPollContractDB(t)
	var visible, hidden []uint
	for i := 0; i < 3; i++ {
		postID, _, _ := seedContractPoll(t, db, author.ID, models.PostStatusNormal)
		visible = append(visible, postID)
	}
	hiddenPostID, _, _ := seedContractPoll(t, db, author.ID, models.PostStatusModeratedHidden)
	hidden = append(hidden, hiddenPostID)
	router := newPollContractRouter(db)

	first := decodePollListResponse(t, doPollContractRequest(t, router, "", http.MethodGet, "/api/polls?sort=latest&limit=2", "").Body.Bytes())
	if total := pollListInt64(t, first, "total"); total != 3 {
		t.Fatalf("latest total = %d，公开的三条投票应全部可翻页（隐藏的 %v 不得计入）", total, hidden)
	}
	if matched := pollListInt64(t, first, "matched_total"); matched != 3 {
		t.Fatalf("latest matched_total = %d", matched)
	}
	if !pollListBool(t, first, "has_more") {
		t.Fatalf("首页只有 2/3 条却声明没有下一页：%v", first)
	}
	second := decodePollListResponse(t, doPollContractRequest(t, router, "", http.MethodGet, "/api/polls?sort=latest&limit=2&page=2", "").Body.Bytes())
	if len(pollListIDs(second)) != 1 {
		t.Fatalf("尾页条数 = %v", pollListIDs(second))
	}
	if pollListBool(t, second, "has_more") {
		t.Fatalf("已经翻到结尾，has_more 仍为 true：%v", second)
	}
	for _, payload := range []map[string]interface{}{first, second} {
		for _, id := range pollListIDs(payload) {
			for _, hiddenID := range hidden {
				if id == hiddenID {
					t.Fatalf("隐藏的投票 %d 出现在列表响应里", hiddenID)
				}
			}
		}
	}
	for _, id := range pollListIDs(first) {
		found := false
		for _, public := range visible {
			if id == public {
				found = true
			}
		}
		if !found {
			t.Fatalf("列表返回了未知投票 %d", id)
		}
	}

	recommended := decodePollListResponse(t, doPollContractRequest(t, router, "", http.MethodGet, "/api/polls?sort=recommend", "").Body.Bytes())
	if poolSize := pollListInt64(t, recommended, "pool_size"); poolSize != pollHTTPRecommendPoolSize {
		t.Fatalf("recommend pool_size = %d，期望 %d", poolSize, pollHTTPRecommendPoolSize)
	}
	if total := pollListInt64(t, recommended, "total"); total != 3 {
		t.Fatalf("recommend total = %d", total)
	}
	if pollListBool(t, recommended, "has_more") {
		t.Fatal("候选池只有一条页时 has_more 仍为 true")
	}
	// 同创建时间的种子投票必须按 id 倒序返回，否则旧客户端只按 total 翻页会重复或漏条。
	if ids := pollListIDs(first); len(ids) == 2 && ids[0] <= ids[1] {
		t.Fatalf("latest 同时间投票未按 id 倒序：%v", ids)
	}
}
