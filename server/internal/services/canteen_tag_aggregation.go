package services

import (
	"encoding/json"
	"sort"
)

// 食堂评价标签聚合。服务端只存储评价的 Tags（JSON 数组字符串），
// 这里在 Go 侧 decode+count，兼容 SQLite / PostgreSQL（避免 json_each 方言差异）。

// CanteenTagName 返回标签 key 的中文显示名；未知 key 返回空串。
// 与 handlers.validCanteenTags 保持一致的显示文案。
var CanteenTagName = map[string]string{
	"taste_good":         "味道不错",
	"portion_enough":     "分量足",
	"price_fair":         "价格合适",
	"serving_fast":       "出餐快",
	"queue_long":         "排队久",
	"recommended_window": "推荐窗口",
	"clean":              "卫生干净",
	"service_warm":       "服务热情",
	"environment_clean":  "环境整洁",
	"good_value":         "性价比高",
}

// SummaryTag 一条聚合后的标签计数。
type SummaryTag struct {
	Key   string `json:"key"`
	Name  string `json:"name"`
	Count int    `json:"count"`
}

// AggregateSummaryTagsInMemory 对一组"原始 Tags 字符串"聚合出按次数降序的 topK 标签。
// tagsJSON 每项是一条 CanteenRating.Tags（JSON 数组字符串）；仅保留白名单标签。
func AggregateSummaryTagsInMemory(tagsJSON []string, topK int) []SummaryTag {
	counter := map[string]int{}
	for _, raw := range tagsJSON {
		if raw == "" {
			continue
		}
		var tags []string
		if err := json.Unmarshal([]byte(raw), &tags); err != nil {
			continue
		}
		for _, k := range tags {
			if _, ok := CanteenTagName[k]; ok {
				counter[k]++
			}
		}
	}
	if len(counter) == 0 {
		return nil
	}
	items := make([]SummaryTag, 0, len(counter))
	for k, n := range counter {
		items = append(items, SummaryTag{Key: k, Name: CanteenTagName[k], Count: n})
	}
	sort.SliceStable(items, func(i, j int) bool {
		if items[i].Count != items[j].Count {
			return items[i].Count > items[j].Count
		}
		return items[i].Key < items[j].Key
	})
	if topK > 0 && len(items) > topK {
		items = items[:topK]
	}
	return items
}
