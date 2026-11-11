package handlers

import (
	"sort"

	"shenliyuan/internal/services"

	"gorm.io/gorm"
)

// CanteenDecayPreviewRow 是一家店开启时间衰减前后的综合排名对比。
type CanteenDecayPreviewRow struct {
	ID           uint    `json:"id"`
	Name         string  `json:"name"`
	RatingCount  int     `json:"rating_count"`
	RankBefore   int     `json:"rank_before"`
	RankAfter    int     `json:"rank_after"`
	ScoreBefore  float64 `json:"score_before"`
	ScoreAfter   float64 `json:"score_after"`
	AverageAfter float64 `json:"average_after"`
}

// PreviewCanteenDecayRanking 只读：用当前数据分别计算不带/带时间衰减的综合排行，
// 供上线前评估哪些店的名次会变化。不写数据库、不动缓存。
func PreviewCanteenDecayRanking(db *gorm.DB) ([]CanteenDecayPreviewRow, error) {
	rank := func(h *CanteenHandler) (map[uint]canteenRankingEntry, error) {
		rows, err := h.queryCanteenStats()
		if err != nil {
			return nil, err
		}
		mean := globalMeanStars(rows)
		entries := make([]canteenRankingEntry, 0, len(rows))
		for _, r := range rows {
			score := services.BayesianRatingScore(r.AverageStar, r.EffectiveSample, mean, services.BayesianPriorWeight)
			entries = append(entries, canteenRankingEntry{canteenStatsRow: r, RankingScore: score})
		}
		sortRanking(entries, "composite")
		byID := make(map[uint]canteenRankingEntry, len(entries))
		for _, entry := range entries {
			byID[entry.ID] = entry
		}
		return byID, nil
	}
	before, err := rank(&CanteenHandler{db: db, disableTimeDecay: true})
	if err != nil {
		return nil, err
	}
	after, err := rank(&CanteenHandler{db: db})
	if err != nil {
		return nil, err
	}
	out := make([]CanteenDecayPreviewRow, 0, len(after))
	for id, a := range after {
		b := before[id]
		out = append(out, CanteenDecayPreviewRow{
			ID: id, Name: a.Name, RatingCount: a.RatingCount,
			RankBefore: b.Rank, RankAfter: a.Rank,
			ScoreBefore:  services.BayesianScoreTo100(b.RankingScore),
			ScoreAfter:   services.BayesianScoreTo100(a.RankingScore),
			AverageAfter: a.AverageStar,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].RankAfter < out[j].RankAfter })
	return out, nil
}
