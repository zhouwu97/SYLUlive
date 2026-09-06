package ai

import (
	"encoding/json"
	"math"

	"shenliyuan/internal/models"
)

const ModelPricingVersion = "gpt-preferred-usd-2026-09-06"

type ModelTokenUsage struct {
	InputTokens      int `json:"input_tokens"`
	OutputTokens     int `json:"output_tokens"`
	CacheHitTokens   int `json:"cache_hit_tokens"`
	CacheWriteTokens int `json:"cache_write_tokens"`
}

// 单位为纳美元/token，精确对应管理员提供的 GPT 优享价表；表内已含倍率，不能再乘 0.2。
// 未列出的模型不套用别的模型价格。零缓存写入价表示价表未提供该项，而非免费。
var preferredModelPrices = map[string]struct{ input, output, write, read int64 }{
	"codex-auto-review":   {40, 240, 50, 4},
	"gpt-5.3-codex-spark": {350, 2800, 0, 35},
	"gpt-5.5":             {1000, 6000, 0, 100},
	"gpt-5.6-luna":        {40, 240, 50, 4},
	"gpt-5.6-sol":         {1000, 6000, 1250, 100},
	"gpt-5.6-terra":       {400, 2400, 500, 40},
	"gpt-6-astra":         {2000, 10000, 2500, 200},
}

// EstimateUsageCostUSD 只重算运营展示，不改动历史预算流水，也不猜测美元兑人民币汇率。
// 历史记录仅按已保存的用量估算；新记录按每个实际调用模型分开核算备用模型费用。
func EstimateUsageCostUSD(record models.AIUsageRecord) (int64, bool) {
	usage := map[string]ModelTokenUsage{}
	if len(record.ModelUsage) > 0 && json.Unmarshal(record.ModelUsage, &usage) != nil {
		return 0, false
	}
	if len(usage) == 0 {
		usage = map[string]ModelTokenUsage{record.Model: {record.InputTokens, record.OutputTokens, record.CacheHitTokens, record.CacheWriteTokens}}
	}
	total := int64(0)
	sum := ModelTokenUsage{}
	for model, item := range usage {
		price, ok := preferredModelPrices[model]
		if !ok || item.InputTokens < 0 || item.OutputTokens < 0 || item.CacheHitTokens < 0 || item.CacheWriteTokens < 0 ||
			item.CacheHitTokens > item.InputTokens || item.CacheWriteTokens > item.InputTokens-item.CacheHitTokens {
			return 0, false
		}
		for _, part := range []struct {
			tokens int
			rate   int64
		}{
			{item.InputTokens - item.CacheHitTokens - item.CacheWriteTokens, price.input},
			{item.OutputTokens, price.output}, {item.CacheHitTokens, price.read}, {item.CacheWriteTokens, price.write},
		} {
			if part.tokens == 0 {
				continue
			}
			if part.rate == 0 || int64(part.tokens) > (math.MaxInt64-total)/part.rate {
				return 0, false
			}
			total += int64(part.tokens) * part.rate
		}
		sum.InputTokens += item.InputTokens
		sum.OutputTokens += item.OutputTokens
		sum.CacheHitTokens += item.CacheHitTokens
		sum.CacheWriteTokens += item.CacheWriteTokens
	}
	if sum.InputTokens != record.InputTokens || sum.OutputTokens != record.OutputTokens || sum.CacheHitTokens != record.CacheHitTokens || sum.CacheWriteTokens != record.CacheWriteTokens {
		return 0, false
	}
	return total, true
}
