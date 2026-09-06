package ai

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
)

func TestRepeatedUsageSnapshotIsNotChargedTwice(t *testing.T) {
	runtime := &Runtime{}
	run := &models.AIRun{Model: "gpt-5.6-terra"}
	initial := mergeProviderUsage(ProviderEvent{}, ProviderEvent{Model: "gpt-5.6-luna", InputTokens: 5, OutputTokens: 2, UsageAvailable: true})
	stream := &sliceProviderStream{events: []ProviderEvent{
		{Type: ProviderEventUsage, InputTokens: 100, OutputTokens: 0, CacheHitTokens: 60, UsageAvailable: true},
		{Type: ProviderEventUsage, InputTokens: 100, OutputTokens: 10, CacheHitTokens: 60, UsageAvailable: true},
		{Type: ProviderEventCompleted},
	}}
	_, _, outcome := runtime.collectProviderRound(context.Background(), run, stream, initial, nil)
	require.Equal(t, 105, outcome.usage.InputTokens)
	require.Equal(t, 12, outcome.usage.OutputTokens)
	require.Equal(t, 60, outcome.usage.CacheHitTokens)
	require.Equal(t, 100, outcome.usage.ModelUsage["gpt-5.6-terra"].InputTokens)
	require.Equal(t, 5, initial.ModelUsage["gpt-5.6-luna"].InputTokens)
	_, mutated := initial.ModelUsage["gpt-5.6-terra"]
	require.False(t, mutated)
}

func TestModelPricingMatchesProvidedDiscountedUSDTable(t *testing.T) {
	for _, tc := range []struct {
		model                      string
		input, output, write, read int64
	}{
		{"codex-auto-review", 40_000_000, 240_000_000, 50_000_000, 4_000_000},
		{"gpt-5.3-codex-spark", 350_000_000, 2_800_000_000, 0, 35_000_000},
		{"gpt-5.5", 1_000_000_000, 6_000_000_000, 0, 100_000_000},
		{"gpt-5.6-luna", 40_000_000, 240_000_000, 50_000_000, 4_000_000},
		{"gpt-5.6-sol", 1_000_000_000, 6_000_000_000, 1_250_000_000, 100_000_000},
		{"gpt-5.6-terra", 400_000_000, 2_400_000_000, 500_000_000, 40_000_000},
		{"gpt-6-astra", 2_000_000_000, 10_000_000_000, 2_500_000_000, 200_000_000},
	} {
		t.Run(tc.model, func(t *testing.T) {
			for _, sample := range []struct {
				in, out, hit, write int
				want                int64
				ok                  bool
			}{
				{1_000_000, 0, 0, 0, tc.input, true}, {0, 1_000_000, 0, 0, tc.output, true},
				{1_000_000, 0, 1_000_000, 0, tc.read, true}, {1_000_000, 0, 0, 1_000_000, tc.write, tc.write > 0},
			} {
				cost, ok := EstimateUsageCostUSD(models.AIUsageRecord{Model: tc.model, InputTokens: sample.in, OutputTokens: sample.out, CacheHitTokens: sample.hit, CacheWriteTokens: sample.write})
				require.Equal(t, sample.ok, ok)
				require.Equal(t, sample.want, cost)
			}
		})
	}
}

func TestModelPricingMixedFallbackAndCacheDoNotDoubleCharge(t *testing.T) {
	usage := mergeProviderUsage(ProviderEvent{}, ProviderEvent{Model: "gpt-5.6-terra", InputTokens: 100, OutputTokens: 10, CacheHitTokens: 60, CacheWriteTokens: 20, UsageAvailable: true})
	usage = mergeProviderUsage(usage, ProviderEvent{Model: "gpt-5.6-luna", InputTokens: 100, OutputTokens: 10, UsageAvailable: true})
	raw, err := json.Marshal(usage.ModelUsage)
	require.NoError(t, err)
	cost, ok := EstimateUsageCostUSD(models.AIUsageRecord{Model: "gpt-5.6-luna", InputTokens: 200, OutputTokens: 20, CacheHitTokens: 60, CacheWriteTokens: 20, ModelUsage: raw})
	require.True(t, ok)
	// terra: 20*400 + 60*40 + 20*500 + 10*2400；luna: 100*40 + 10*240。
	require.Equal(t, int64(50_800), cost)
}

func TestModelPricingDoesNotInventHistoricalPriceOrCacheData(t *testing.T) {
	for _, record := range []models.AIUsageRecord{
		{Model: "gpt-5.4-mini", InputTokens: 100},
		{Model: "gpt-5.6-terra", InputTokens: 10, CacheHitTokens: 11},
		{Model: "gpt-5.6-terra", InputTokens: -1},
		{Model: "gpt-5.6-terra", InputTokens: 100, ModelUsage: []byte(`{"gpt-5.6-terra":{"input_tokens":10}}`)},
	} {
		_, ok := EstimateUsageCostUSD(record)
		require.False(t, ok)
	}
	// 截图时已有的 terra / luna 记录只用已保存用量，不能倒推过去的缓存命中。
	terra, _ := EstimateUsageCostUSD(models.AIUsageRecord{Model: "gpt-5.6-terra", InputTokens: 3476, OutputTokens: 759})
	luna, _ := EstimateUsageCostUSD(models.AIUsageRecord{Model: "gpt-5.6-luna", InputTokens: 3814, OutputTokens: 115})
	require.Equal(t, int64(3_392_160), terra+luna)
}
