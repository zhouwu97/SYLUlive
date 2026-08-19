package handlers

import (
	"fmt"
	"sort"
	"strconv"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
)

// canteenDiscoveryCache 首页与排行页的共享内存缓存（TTL 60s，变更时主动失效）。
var canteenDiscoveryCache = services.NewCanteenDiscoveryCache(60 * time.Second)

// summaryTagDays 标签聚合的默认回溯天数。
const summaryTagDays = 30

// aggregateSummaryTags 统计某食堂近 days 天内评价里出现的标签 topK（只留白名单）。
// 数据不足时返回空数组，调用方回退文案。
func (h *CanteenHandler) aggregateSummaryTags(canteenID uint, days int, topK int) []services.SummaryTag {
	if days <= 0 {
		days = summaryTagDays
	}
	since := time.Now().AddDate(0, 0, -days)
	var raws []string
	err := h.db.Table("canteen_ratings").
		Where("canteen_id = ? AND created_at >= ?", canteenID, since).
		Where("tags IS NOT NULL AND tags <> '' AND tags <> '[]'").
		Pluck("tags", &raws).Error
	if err != nil {
		return nil
	}
	return services.AggregateSummaryTagsInMemory(raws, topK)
}

// GetRankings 食堂完整排行（sort=composite|rating|review_count；hot 暂不开放）。
func (h *CanteenHandler) GetRankings(c *gin.Context) {
	sortMode := c.DefaultQuery("sort", "composite")
	switch sortMode {
	case "composite", "rating", "review_count":
	default:
		sortMode = "composite"
	}

	cacheKey := "rankings:" + sortMode
	if cached, ok := canteenDiscoveryCache.Get(cacheKey); ok {
		c.JSON(200, cached)
		return
	}

	rows, err := h.queryCanteenStats()
	if err != nil {
		c.JSON(500, gin.H{"error": "获取排行失败"})
		return
	}
	mean := globalMeanStars(rows)
	entries := make([]canteenRankingEntry, 0, len(rows))
	for _, r := range rows {
		score := services.BayesianRatingScore(r.AverageStar, float64(r.RatingCount), mean, services.BayesianPriorWeight)
		entries = append(entries, canteenRankingEntry{canteenStatsRow: r, RankingScore: score})
	}
	sortRanking(entries, sortMode)

	type item struct {
		Rank           int                   `json:"rank"`
		ID             uint                  `json:"id"`
		Name           string                `json:"name"`
		Image          string                `json:"image"`
		AverageStar    float64               `json:"average_star"`
		RatingCount    int                   `json:"rating_count"`
		RankingScore   float64               `json:"ranking_score"`
		Confidence     string                `json:"confidence"`
		DishCount      int                   `json:"dish_count"`
		DishPhotoCount int                   `json:"dish_photo_count"`
		SummaryTags    []services.SummaryTag `json:"summary_tags"`
	}
	items := make([]item, 0, len(entries))
	for _, e := range entries {
		items = append(items, item{
			Rank:           e.Rank,
			ID:             e.ID,
			Name:           e.Name,
			Image:          e.Image,
			AverageStar:    e.AverageStar,
			RatingCount:    e.RatingCount,
			RankingScore:   e.RankingScore,
			Confidence:     services.RatingConfidence(e.RatingCount),
			DishCount:      e.DishCount,
			DishPhotoCount: e.DishPhotoCount,
			SummaryTags:    h.aggregateSummaryTags(e.ID, summaryTagDays, 3),
		})
	}

	resp := gin.H{
		"items": items,
		"meta": gin.H{
			"sort":         sortMode,
			"algorithm":    "bayesian",
			"prior_weight": services.BayesianPriorWeight,
			"updated_at":   time.Now(),
			"total":        len(items),
		},
	}
	canteenDiscoveryCache.Set(cacheKey, resp)
	c.JSON(200, resp)
}

// ── 首页发现聚合（GET /canteens/home）─────────────────────────────────────
//
// 首页一次性返回 hero 推荐 / 排行入口 / 推荐信息流，避免 Flutter 发多个接口。
// 第一版只使用现有真实数据（verified 食堂、真实评价、approved 实拍），不做个性化：
//   - recommended_store：贝叶斯综合分最高的「有评价」食堂 + 标签理由
//   - stable_choice：样本较多、近期评价稳定的食堂
//   - trending：近 7 天新增评价最多的食堂（热度表未上线前的轻量统计）
//   - recent_photo：最近 approved 实拍
//
// 多样性约束在 BuildHomeFeed 内保证：同店每屏最多 2 次、不相邻连续、类型尽量交替。

// canteenFeedItem 首页信息流条目（对应客户端 CanteenFeedItem）。
type canteenFeedItem struct {
	ID           string   `json:"id"`
	Type         string   `json:"type"`
	CanteenID    uint     `json:"canteen_id"`
	CanteenName  string   `json:"canteen_name"`
	Image        string   `json:"image,omitempty"`
	DishID       uint     `json:"dish_id,omitempty"`
	DishName     string   `json:"dish_name,omitempty"`
	Title        string   `json:"title"`
	Reason       string   `json:"reason,omitempty"`
	RankingScore float64  `json:"ranking_score,omitempty"`
	AverageStar  float64  `json:"average_star,omitempty"`
	RatingCount  int      `json:"rating_count,omitempty"`
	Tags         []string `json:"tags,omitempty"`
	Images       []string `json:"images,omitempty"`
	CreatedAt    string   `json:"created_at,omitempty"`
}

// recentReviewCount 统计某食堂近 days 天内的评价数。
func (h *CanteenHandler) recentReviewCount(canteenID uint, days int) int64 {
	var n int64
	h.db.Table("canteen_ratings").
		Where("canteen_id = ? AND created_at >= ?", canteenID, time.Now().AddDate(0, 0, -days)).
		Count(&n)
	return n
}

// buildFeedReason 由近 30 天标签聚合生成一句稳定、可解释的推荐理由。
// 无标签时回退到真实评分文案，绝不编造营业时间/价格/口味等不存在信息。
func buildFeedReason(tags []services.SummaryTag, averageStar float64, ratingCount int) string {
	if len(tags) >= 2 {
		return "同学们常常提到“" + tags[0].Name + "”和“" + tags[1].Name + "”"
	}
	if len(tags) == 1 {
		return "同学们常常提到“" + tags[0].Name + "”"
	}
	if ratingCount > 0 {
		return "真实评分 " + trimFloat(averageStar, 1) + " · " + itoa(ratingCount) + " 人评价"
	}
	return "暂无足够评分，先看看同学实拍"
}

// BuildHomeFeed 规则型首页信息流：多类型混合 + 多样性控制（同店不连续、不刷屏）。
func (h *CanteenHandler) BuildHomeFeed(entries []canteenRankingEntry, mean float64, limit int) []canteenFeedItem {
	// 1. 候选池按类型组织，各自按质量/新鲜度排序。
	recommendations := make([]canteenRankingEntry, 0) // 有评价，按推荐分
	stable := make([]canteenRankingEntry, 0)           // 样本较多且近期仍有评价
	trending := make([]canteenRankingEntry, 0)         // 近 7 天评价数
	for _, e := range entries {
		if e.RatingCount == 0 {
			continue
		}
		recommendations = append(recommendations, e)
		if e.RatingCount >= 3 {
			stable = append(stable, e)
		}
		if h.recentReviewCount(e.ID, 7) > 0 {
			trending = append(trending, e)
		}
	}
	if len(recommendations) > 1 {
		sort.SliceStable(recommendations, func(i, j int) bool {
			return recommendations[i].RankingScore > recommendations[j].RankingScore
		})
	}
	if len(stable) > 1 {
		sort.SliceStable(stable, func(i, j int) bool {
			// 样本多者更“稳”优先；同样本取综合分高者。
			if stable[i].RatingCount != stable[j].RatingCount {
				return stable[i].RatingCount > stable[j].RatingCount
			}
			return stable[i].RankingScore > stable[j].RankingScore
		})
	}
	if len(trending) > 1 {
		sort.SliceStable(trending, func(i, j int) bool {
			return recentReviewCountStatic(h, trending[i].ID) > recentReviewCountStatic(h, trending[j].ID)
		})
	}

	// 2. 最近 approved 实拍（跨食堂取最新 N 条）。
	photoItems := h.latestApprovedPhotos(6)

	// 3. 稳定 ID + 多样性拼接。
	feed := make([]canteenFeedItem, 0, limit)
	seenCanteenCount := map[uint]int{}
	lastCanteen := uint(0)
	lastType := ""

	types := []string{"recommended_store", "recent_photo", "trending", "stable_choice"}
	for len(feed) < limit && types != nil {
		progressed := false
		for _, t := range types {
			if len(feed) >= limit {
				break
			}
			var item *canteenFeedItem
			switch t {
			case "recommended_store":
				item = h.pickRecommendation(recommendations, seenCanteenCount, lastCanteen, lastType)
			case "stable_choice":
				item = h.pickStable(stable, seenCanteenCount, lastCanteen, lastType, mean)
			case "trending":
				item = h.pickTrending(trending, seenCanteenCount, lastCanteen, lastType, mean)
			case "recent_photo":
				item = pickPhoto(photoItems, seenCanteenCount, lastCanteen, lastType)
			}
			if item == nil {
				continue
			}
			feed = append(feed, *item)
			seenCanteenCount[item.CanteenID]++
			lastCanteen = item.CanteenID
			lastType = item.Type
			progressed = true
			if seenCanteenCount[item.CanteenID] >= 2 {
				// 该店本屏出现满 2 次后，从所有候选池移除。
				recommendations = removeCanteen(recommendations, item.CanteenID)
				stable = removeCanteen(stable, item.CanteenID)
				trending = removeCanteen(trending, item.CanteenID)
				photoItems = removePhotoCanteen(photoItems, item.CanteenID)
			}
		}
		if !progressed {
			break
		}
	}
	return feed
}

// pickRecommendation 从推荐候选池挑一条「同店未满 2 次、不与上一条同店、类型不重复」的卡。
func (h *CanteenHandler) pickRecommendation(pool []canteenRankingEntry, seen map[uint]int, lastCanteen uint, lastType string) *canteenFeedItem {
	for i := range pool {
		e := pool[i]
		if seen[e.ID] >= 2 {
			continue
		}
		if lastCanteen == e.ID {
			continue
		}
		if lastType == "recommended_store" {
			continue
		}
		tags := h.aggregateSummaryTags(e.ID, summaryTagDays, 2)
		names := make([]string, len(tags))
		for j, t := range tags {
			names[j] = t.Name
		}
		return &canteenFeedItem{
			ID:          fmt.Sprintf("recommended_store:%d:v1", e.ID),
			Type:        "recommended_store",
			CanteenID:   e.ID,
			CanteenName: e.Name,
			Image:       e.Image,
			Title:       "今天想吃得下饭一点？",
			Reason:      buildFeedReason(tags, e.AverageStar, e.RatingCount),
			RankingScore: e.RankingScore,
			AverageStar:  e.AverageStar,
			RatingCount:  e.RatingCount,
			Tags:         names,
		}
	}
	return nil
}

// pickStable 从样本较多、近期仍有评价的店里挑「稳妥选择」。
func (h *CanteenHandler) pickStable(pool []canteenRankingEntry, seen map[uint]int, lastCanteen uint, lastType string, mean float64) *canteenFeedItem {
	for i := range pool {
		e := pool[i]
		if seen[e.ID] >= 2 || lastCanteen == e.ID || lastType == "stable_choice" {
			continue
		}
		tags := h.aggregateSummaryTags(e.ID, summaryTagDays, 2)
		names := make([]string, len(tags))
		for j, t := range tags {
			names[j] = t.Name
		}
		return &canteenFeedItem{
			ID:          fmt.Sprintf("stable_choice:%d:v1", e.ID),
			Type:        "stable_choice",
			CanteenID:   e.ID,
			CanteenName: e.Name,
			Image:       e.Image,
			Title:       "想吃稳一点？",
			Reason:      "评价样本较多，近期反馈比较稳定",
			RankingScore: e.RankingScore,
			AverageStar:  e.AverageStar,
			RatingCount:  e.RatingCount,
			Tags:         names,
		}
	}
	return nil
}

// pickTrending 从近 7 天有评价的店里挑「最近有人吃」的卡（热度表上线前的轻量统计）。
func (h *CanteenHandler) pickTrending(pool []canteenRankingEntry, seen map[uint]int, lastCanteen uint, lastType string, mean float64) *canteenFeedItem {
	for i := range pool {
		e := pool[i]
		if seen[e.ID] >= 2 || lastCanteen == e.ID || lastType == "trending" {
			continue
		}
		recent := h.recentReviewCount(e.ID, 7)
		tags := h.aggregateSummaryTags(e.ID, summaryTagDays, 2)
		names := make([]string, len(tags))
		for j, t := range tags {
			names[j] = t.Name
		}
		return &canteenFeedItem{
			ID:          fmt.Sprintf("trending:%d:v1", e.ID),
			Type:        "trending",
			CanteenID:   e.ID,
			CanteenName: e.Name,
			Image:       e.Image,
			Title:       "最近大家也在吃",
			Reason:      fmt.Sprintf("近 7 天新增 %d 条评价", recent),
			RankingScore: e.RankingScore,
			AverageStar:  e.AverageStar,
			RatingCount:  e.RatingCount,
			Tags:         names,
		}
	}
	return nil
}

func removeCanteen(pool []canteenRankingEntry, id uint) []canteenRankingEntry {
	out := pool[:0]
	for _, e := range pool {
		if e.ID != id {
			out = append(out, e)
		}
	}
	return out
}

// latestApprovedPhotos 最近 approved 实拍（跨食堂、仅 return 审核通过的图片）。
func (h *CanteenHandler) latestApprovedPhotos(limit int) []canteenPhotoItem {
	type row struct {
		DishID       uint
		DishName     string
		CanteenID    uint
		CanteenName  string
		Image        string
		CreatedAt    time.Time
	}
	var rows []row
	if err := h.db.Table("canteen_dish_photos AS p").
		Joins("JOIN files f ON f.id = p.file_id").
		Joins("JOIN canteen_dishes d ON d.id = p.dish_id AND d.status = ?", models.DishStatusActive).
		Joins("JOIN canteens c ON c.id = d.canteen_id AND c.verified = ?", true).
		Select("p.dish_id AS dish_id, d.name AS dish_name, d.canteen_id AS canteen_id, c.name AS canteen_name, f.path AS image, p.created_at AS created_at").
		Where("p.status = ?", models.DishPhotoStatusApproved).
		Order("p.created_at DESC, p.id DESC").
		Limit(limit).
		Scan(&rows).Error; err != nil {
		return nil
	}

	items := make([]canteenPhotoItem, 0, len(rows))
	for _, r := range rows {
		items = append(items, canteenPhotoItem{
			CanteenID:   r.CanteenID,
			CanteenName: r.CanteenName,
			DishID:      r.DishID,
			DishName:    r.DishName,
			Image:       r.Image,
			CreatedAt:   r.CreatedAt,
		})
	}
	return items
}

type canteenPhotoItem struct {
	CanteenID   uint
	CanteenName string
	DishID      uint
	DishName    string
	Image       string
	CreatedAt   time.Time
}

func pickPhoto(pool []canteenPhotoItem, seen map[uint]int, lastCanteen uint, lastType string) *canteenFeedItem {
	for i := range pool {
		p := pool[i]
		if seen[p.CanteenID] >= 2 || lastCanteen == p.CanteenID {
			continue
		}
		return &canteenFeedItem{
			ID:          fmt.Sprintf("recent_photo:%d", pool[i].DishID),
			Type:        "recent_photo",
			CanteenID:   p.CanteenID,
			CanteenName: p.CanteenName,
			DishID:      p.DishID,
			DishName:    p.DishName,
			Title:       "同学最近实拍",
			Reason:      p.DishName + " · 看看最近实际卖相",
			Images:      []string{p.Image},
			CreatedAt:   p.CreatedAt.Format("2006-01-02 15:04:05"),
		}
	}
	return nil
}

func removePhotoCanteen(pool []canteenPhotoItem, canteenID uint) []canteenPhotoItem {
	out := pool[:0]
	for _, p := range pool {
		if p.CanteenID != canteenID {
			out = append(out, p)
		}
	}
	return out
}

func recentReviewCountStatic(h *CanteenHandler, canteenID uint) int64 {
	return h.recentReviewCount(canteenID, 7)
}

func trimFloat(v float64, digits int) string {
	return strconv.FormatFloat(v, 'f', digits, 64)
}

func itoa(v int) string {
	return strconv.Itoa(v)
}

// GetHome 食堂发现首页聚合。GET /api/canteens/home
func (h *CanteenHandler) GetHome(c *gin.Context) {
	cacheKey := "home:v1"
	if cached, ok := canteenDiscoveryCache.Get(cacheKey); ok {
		c.JSON(200, cached)
		return
	}

	rows, err := h.queryCanteenStats()
	if err != nil {
		c.JSON(500, gin.H{"error": "获取首页失败"})
		return
	}
	mean := globalMeanStars(rows)

	// 全部 verified 食堂（含无评价，用作冷启动）。
	entries := make([]canteenRankingEntry, 0, len(rows))
	for _, r := range rows {
		score := services.BayesianRatingScore(r.AverageStar, float64(r.RatingCount), mean, services.BayesianPriorWeight)
		entries = append(entries, canteenRankingEntry{canteenStatsRow: r, RankingScore: score})
	}
	sortRanking(entries, "composite")

	// Hero：综合分最高的「有评价」食堂。
	var hero *canteenFeedItem
	for _, e := range entries {
		if e.RatingCount == 0 {
			continue
		}
		tags := h.aggregateSummaryTags(e.ID, summaryTagDays, 3)
		tagNames := make([]string, 0, len(tags))
		for _, t := range tags {
			tagNames = append(tagNames, t.Name)
		}
		h := &canteenFeedItem{
			ID:           fmt.Sprintf("recommended_store:%d:v1", e.ID),
			Type:         "recommended_store",
			CanteenID:    e.ID,
			CanteenName:  e.Name,
			Image:        e.Image,
			Title:        "今日推荐",
			Reason:       buildFeedReason(tags, e.AverageStar, e.RatingCount),
			RankingScore: e.RankingScore,
			AverageStar:  e.AverageStar,
			RatingCount:  e.RatingCount,
			Tags:         tagNames,
		}
		hero = h
		break
	}

	// 排行入口：第一名 + 总数。
	rankTotal := len(entries)
	type topItem struct {
		ID           uint    `json:"id"`
		Name         string  `json:"name"`
		RankingScore float64 `json:"ranking_score"`
	}
	var top topItem
	if len(entries) > 0 {
		top = topItem{ID: entries[0].ID, Name: entries[0].Name, RankingScore: entries[0].RankingScore}
	}
	rankingEntry := gin.H{
		"top":   top,
		"total": rankTotal,
	}

	feed := h.BuildHomeFeed(entries, mean, 8)

	resp := gin.H{
		"generated_at":   time.Now(),
		"hero":           hero,
		"ranking_entry":  rankingEntry,
		"feed":           feed,
	}
	canteenDiscoveryCache.Set(cacheKey, resp)
	c.JSON(200, resp)
}
