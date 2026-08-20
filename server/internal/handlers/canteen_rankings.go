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

// batchAggregateSummaryTags 批量拉取近 days 天内评价标签并在 Go 内存中按食堂分组聚合 topK（只留白名单）。
// 消除按店 N+1 查询。
func (h *CanteenHandler) batchAggregateSummaryTags(days int, topK int) map[uint][]services.SummaryTag {
	if days <= 0 {
		days = summaryTagDays
	}
	since := time.Now().AddDate(0, 0, -days)
	type ratingTagRow struct {
		CanteenID uint   `gorm:"column:canteen_id"`
		Tags      string `gorm:"column:tags"`
	}
	var rows []ratingTagRow
	_ = h.db.Table("canteen_review_events AS e").
		Select("e.canteen_id, e.tags").
		Where("e.status = ? AND e.score_version >= ? AND e.created_at >= ?", models.ReviewEventStatusActive, 2, since).
		Where("e.tags IS NOT NULL AND e.tags <> '' AND e.tags <> '[]'").
		Scan(&rows).Error
	var legacyRows []ratingTagRow
	_ = h.db.Table("canteen_ratings AS r").
		Select("r.canteen_id, r.tags").
		Where("(r.status = ? OR r.status IS NULL OR r.status = '') AND r.created_at >= ?", models.ReviewEventStatusActive, since).
		Where("r.tags IS NOT NULL AND r.tags <> '' AND r.tags <> '[]'").
		Where("NOT EXISTS (SELECT 1 FROM canteen_review_events e WHERE e.canteen_id = r.canteen_id AND e.user_id = r.user_id AND e.status = ? AND (e.score_version >= ? OR e.score_version = ?))", models.ReviewEventStatusActive, 2, 0).
		Scan(&legacyRows).Error
	rows = append(rows, legacyRows...)

	canteenRaws := make(map[uint][]string, len(rows))
	for _, r := range rows {
		canteenRaws[r.CanteenID] = append(canteenRaws[r.CanteenID], r.Tags)
	}

	result := make(map[uint][]services.SummaryTag, len(canteenRaws))
	for cid, raws := range canteenRaws {
		result[cid] = services.AggregateSummaryTagsInMemory(raws, topK)
	}
	return result
}

// aggregateSummaryTags 单店查询包装（向前兼容）。
func (h *CanteenHandler) aggregateSummaryTags(canteenID uint, days int, topK int) []services.SummaryTag {
	if days <= 0 {
		days = summaryTagDays
	}
	since := time.Now().AddDate(0, 0, -days)
	var raws []string
	err := h.db.Table("canteen_review_events AS e").
		Where("e.canteen_id = ? AND e.status = ? AND e.score_version >= ? AND e.created_at >= ?", canteenID, models.ReviewEventStatusActive, 2, since).
		Where("e.tags IS NOT NULL AND e.tags <> '' AND e.tags <> '[]'").
		Pluck("e.tags", &raws).Error
	var legacyRaws []string
	_ = h.db.Table("canteen_ratings AS r").
		Where("r.canteen_id = ? AND (r.status = ? OR r.status IS NULL OR r.status = '') AND r.created_at >= ?", canteenID, models.ReviewEventStatusActive, since).
		Where("r.tags IS NOT NULL AND r.tags <> '' AND r.tags <> '[]'").
		Where("NOT EXISTS (SELECT 1 FROM canteen_review_events e WHERE e.canteen_id = r.canteen_id AND e.user_id = r.user_id AND e.status = ? AND (e.score_version >= ? OR e.score_version = ?))", models.ReviewEventStatusActive, 2, 0).
		Pluck("r.tags", &legacyRaws)
	raws = append(raws, legacyRaws...)
	if err != nil {
		return nil
	}
	return services.AggregateSummaryTagsInMemory(raws, topK)
}

// batchRecentReviewCounts 批量统计所有食堂近 days 天内的评价事件数（消除按店 N+1）。
func (h *CanteenHandler) batchRecentReviewCounts(days int) map[uint]int64 {
	type countRow struct {
		CanteenID uint  `gorm:"column:canteen_id"`
		Cnt       int64 `gorm:"column:cnt"`
	}
	var rows []countRow
	since := time.Now().AddDate(0, 0, -days)
	_ = h.db.Table("canteen_review_events").
		Select("canteen_id, COUNT(*) as cnt").
		Where("status = ? AND score_version >= ? AND created_at >= ?", models.ReviewEventStatusActive, 2, since).
		Group("canteen_id").
		Scan(&rows).Error
	var legacyRows []countRow
	_ = h.db.Table("canteen_ratings AS r").
		Select("r.canteen_id, COUNT(*) as cnt").
		Where("(r.status = ? OR r.status IS NULL OR r.status = '') AND r.created_at >= ?", models.ReviewEventStatusActive, since).
		Where("NOT EXISTS (SELECT 1 FROM canteen_review_events e WHERE e.canteen_id = r.canteen_id AND e.user_id = r.user_id AND e.status = ? AND (e.score_version >= ? OR e.score_version = ?))", models.ReviewEventStatusActive, 2, 0).
		Group("r.canteen_id").
		Scan(&legacyRows).Error
	rows = append(rows, legacyRows...)

	counts := make(map[uint]int64, len(rows))
	for _, r := range rows {
		counts[r.CanteenID] += r.Cnt
	}
	return counts
}

// recentReviewCount 统计某食堂近 days 天内的评价数。
func (h *CanteenHandler) recentReviewCount(canteenID uint, days int) int64 {
	var n int64
	h.db.Table("canteen_review_events").
		Where("canteen_id = ? AND status = ? AND score_version >= 2 AND created_at >= ?", canteenID, models.ReviewEventStatusActive, time.Now().AddDate(0, 0, -days)).
		Count(&n)
	var legacyCount int64
	h.db.Table("canteen_ratings AS r").
		Where("r.canteen_id = ? AND (r.status = ? OR r.status IS NULL OR r.status = '') AND r.created_at >= ?", canteenID, models.ReviewEventStatusActive, time.Now().AddDate(0, 0, -days)).
		Where("NOT EXISTS (SELECT 1 FROM canteen_review_events e WHERE e.canteen_id = r.canteen_id AND e.user_id = r.user_id AND e.status = ? AND (e.score_version >= ? OR e.score_version = ?))", models.ReviewEventStatusActive, 2, 0).
		Count(&legacyCount)
	n += legacyCount
	return n
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
	generation := canteenDiscoveryCache.Generation()
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
		score := services.BayesianRatingScore(r.AverageStar, r.EffectiveSample, mean, services.BayesianPriorWeight)
		entries = append(entries, canteenRankingEntry{canteenStatsRow: r, RankingScore: score})
	}
	sortRanking(entries, sortMode)

	// 批量拉取近 30 天评价标签，避免 N+1
	tagMap := h.batchAggregateSummaryTags(summaryTagDays, 3)

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
			RankingScore:   services.BayesianScoreTo100(e.RankingScore),
			Confidence:     services.RatingConfidenceEffective(e.EffectiveSample),
			DishCount:      e.DishCount,
			DishPhotoCount: e.DishPhotoCount,
			SummaryTags:    tagMap[e.ID],
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
	canteenDiscoveryCache.SetIfGeneration(cacheKey, resp, generation)
	c.JSON(200, resp)
}

// ── 首页发现聚合（GET /canteens/home）─────────────────────────────────────
//
// 首页一次性返回 hero 推荐 / 排行入口 / 推荐信息流，避免 Flutter 发多个接口。
// 第一版只使用现有真实数据（verified 食堂、真实评价、approved 实拍），不做个性化：
//   - recommended_store：贝叶斯综合分最高的「有评价」食堂 + 标签理由
//   - stable_choice：评价样本相对较多的食堂（受单条评价波动小）
//   - trending：近 7 天新增评价最多的食堂（热度表未上线前的轻量统计）
//   - recent_photo：最近 approved 实拍
//
// 多样性约束在 BuildHomeFeed 内保证：同店每屏最多 1 次、不相邻连续、类型尽量交替。

// canteenFeedItem 首页信息流条目（对应客户端 CanteenFeedItem）。
type canteenFeedItem struct {
	ID                string             `json:"id"`
	Type              string             `json:"type"`
	CanteenID         uint               `json:"canteen_id"`
	CanteenName       string             `json:"canteen_name"`
	OperatingStatus   string             `json:"operating_status"`
	Image             string             `json:"image,omitempty"`
	DishID            uint               `json:"dish_id,omitempty"`
	DishName          string             `json:"dish_name,omitempty"`
	Title             string             `json:"title"`
	Reason            string             `json:"reason,omitempty"`
	RankingScore      float64            `json:"ranking_score,omitempty"`
	AverageStar       float64            `json:"average_star,omitempty"`
	RatingCount       int                `json:"rating_count,omitempty"`
	Tags              []string           `json:"tags,omitempty"`
	Images            []string           `json:"images,omitempty"`
	CreatedAt         string             `json:"created_at,omitempty"`
	DimensionScores   map[string]float64 `json:"dimension_scores,omitempty"`
	ReviewerCount     int                `json:"reviewer_count,omitempty"`
	VisitReviewCount  int                `json:"visit_review_count,omitempty"`
	RecentReviewCount int                `json:"recent_review_count,omitempty"`
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

// takeSummaryTags 安全截取前 k 个标签。
func takeSummaryTags(tags []services.SummaryTag, k int) []services.SummaryTag {
	if len(tags) <= k {
		return tags
	}
	return tags[:k]
}

// BuildHomeFeed 规则型首页信息流：多类型混合 + 多样性控制（同店不连续、不刷屏）。
// 支持外部传入已批量统计的 recentCounts 和 summaryTags，避免多次查询 DB 与在 sort 比较器内查询 DB。
func (h *CanteenHandler) BuildHomeFeed(
	entries []canteenRankingEntry,
	mean float64,
	limit int,
	recentCounts map[uint]int64,
	summaryTags map[uint][]services.SummaryTag,
) []canteenFeedItem {
	if recentCounts == nil {
		recentCounts = h.batchRecentReviewCounts(7)
	}
	if summaryTags == nil {
		summaryTags = h.batchAggregateSummaryTags(summaryTagDays, 3)
	}

	// 1. 候选池按类型组织，各自按质量/新鲜度排序。
	recommendations := make([]canteenRankingEntry, 0) // 有评价，按推荐分
	stable := make([]canteenRankingEntry, 0)          // 样本较多
	trending := make([]canteenRankingEntry, 0)        // 近 7 天评价数
	for _, e := range entries {
		if e.RatingCount == 0 {
			continue
		}
		recommendations = append(recommendations, e)
		if e.RatingCount >= 3 {
			stable = append(stable, e)
		}
		if recentCounts[e.ID] > 0 {
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
			// 纯内存比较，绝不在 sort 内部查询数据库
			ci, cj := recentCounts[trending[i].ID], recentCounts[trending[j].ID]
			if ci != cj {
				return ci > cj
			}
			return trending[i].RankingScore > trending[j].RankingScore
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
				item = h.pickRecommendation(recommendations, seenCanteenCount, lastCanteen, lastType, summaryTags)
			case "stable_choice":
				item = h.pickStable(stable, seenCanteenCount, lastCanteen, lastType, mean, summaryTags)
			case "trending":
				item = h.pickTrending(trending, seenCanteenCount, lastCanteen, lastType, mean, recentCounts, summaryTags)
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
			// 每店信息流最多出现 1 次（避免同店刷屏，也避免首页同 tag 的 Hero 冲突）。
			recommendations = removeCanteen(recommendations, item.CanteenID)
			stable = removeCanteen(stable, item.CanteenID)
			trending = removeCanteen(trending, item.CanteenID)
			photoItems = removePhotoCanteen(photoItems, item.CanteenID)
		}
		if !progressed {
			break
		}
	}
	return feed
}

// pickRecommendation 从推荐候选池挑一条「同店最多 1 次、不与上一条同店、类型不重复」的卡。
func (h *CanteenHandler) pickRecommendation(pool []canteenRankingEntry, seen map[uint]int, lastCanteen uint, lastType string, summaryTags map[uint][]services.SummaryTag) *canteenFeedItem {
	for i := range pool {
		e := pool[i]
		if seen[e.ID] >= 1 {
			continue
		}
		if lastCanteen == e.ID {
			continue
		}
		if lastType == "recommended_store" {
			continue
		}
		tags := takeSummaryTags(summaryTags[e.ID], 2)
		names := make([]string, len(tags))
		for j, t := range tags {
			names[j] = t.Name
		}
		return &canteenFeedItem{
			ID:              fmt.Sprintf("recommended_store:%d:v1", e.ID),
			Type:            "recommended_store",
			CanteenID:       e.ID,
			CanteenName:     e.Name,
			OperatingStatus: e.OperatingStatus,
			Image:           e.Image,
			// Title 仅保留兼容字段；首页客户端使用 Type 映射轻量标签，
			// 不再把推荐理由当作店铺卡主标题。
			Title:        "综合推荐",
			Reason:       buildFeedReason(tags, e.AverageStar, e.RatingCount),
			RankingScore: services.BayesianScoreTo100(e.RankingScore),
			AverageStar:  e.AverageStar,
			RatingCount:  e.RatingCount,
			Tags:         names,
		}
	}
	return nil
}

// pickStable 从样本相对较多的店里挑「稳妥选择」。
func (h *CanteenHandler) pickStable(pool []canteenRankingEntry, seen map[uint]int, lastCanteen uint, lastType string, mean float64, summaryTags map[uint][]services.SummaryTag) *canteenFeedItem {
	for i := range pool {
		e := pool[i]
		if seen[e.ID] >= 1 || lastCanteen == e.ID || lastType == "stable_choice" {
			continue
		}
		tags := takeSummaryTags(summaryTags[e.ID], 2)
		names := make([]string, len(tags))
		for j, t := range tags {
			names[j] = t.Name
		}
		return &canteenFeedItem{
			ID:              fmt.Sprintf("stable_choice:%d:v1", e.ID),
			Type:            "stable_choice",
			CanteenID:       e.ID,
			CanteenName:     e.Name,
			OperatingStatus: e.OperatingStatus,
			Image:           e.Image,
			Title:           "评价稳定",
			Reason:          "评价样本相对更多，结果受单条评价影响更小",
			RankingScore:    services.BayesianScoreTo100(e.RankingScore),
			AverageStar:     e.AverageStar,
			RatingCount:     e.RatingCount,
			Tags:            names,
		}
	}
	return nil
}

// pickTrending 从近 7 天有评价的店里挑「最近有人吃」的卡（热度表上线前的轻量统计）。
func (h *CanteenHandler) pickTrending(pool []canteenRankingEntry, seen map[uint]int, lastCanteen uint, lastType string, mean float64, recentCounts map[uint]int64, summaryTags map[uint][]services.SummaryTag) *canteenFeedItem {
	for i := range pool {
		e := pool[i]
		if seen[e.ID] >= 1 || lastCanteen == e.ID || lastType == "trending" {
			continue
		}
		recent := recentCounts[e.ID]
		tags := takeSummaryTags(summaryTags[e.ID], 2)
		names := make([]string, len(tags))
		for j, t := range tags {
			names[j] = t.Name
		}
		return &canteenFeedItem{
			ID:              fmt.Sprintf("trending:%d:v1", e.ID),
			Type:            "trending",
			CanteenID:       e.ID,
			CanteenName:     e.Name,
			OperatingStatus: e.OperatingStatus,
			Image:           e.Image,
			Title:           "近期热门",
			Reason:          fmt.Sprintf("近 7 天新增 %d 条评价", recent),
			RankingScore:    services.BayesianScoreTo100(e.RankingScore),
			AverageStar:     e.AverageStar,
			RatingCount:     e.RatingCount,
			Tags:            names,
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
		DishID      uint
		DishName    string
		CanteenID   uint
		CanteenName string
		Image       string
		CreatedAt   time.Time
	}
	var rows []row
	if err := h.db.Table("canteen_dish_photos AS p").
		Joins("JOIN files f ON f.id = p.file_id").
		Joins("JOIN canteen_dishes d ON d.id = p.dish_id AND d.status = ?", models.DishStatusActive).
		Joins("JOIN canteens c ON c.id = d.canteen_id AND c.verified = ? AND (c.operating_status = ? OR c.operating_status IS NULL OR c.operating_status = '')", true, models.CanteenOperatingActive).
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

// canteenHotDishItem 首页“热门菜品”卡，数据只来自已上架菜品、审核通过实拍和 V2 菜品摘要。
type canteenHotDishItem struct {
	ID                     uint    `json:"id"`
	Name                   string  `json:"name"`
	CanteenID              uint    `json:"canteen_id"`
	CanteenName            string  `json:"canteen_name"`
	CanteenOperatingStatus string  `json:"canteen_operating_status"`
	CoverImage             string  `json:"cover_image,omitempty"`
	PhotoCount             int     `json:"photo_count"`
	AverageScore           float64 `json:"average_score"`
	ReviewerCount          int     `json:"reviewer_count"`
}

// hotDishes 首页热菜：先取有真实实拍的 active 菜品，再在 Go 层按诚信加权后的菜品摘要排序。
func (h *CanteenHandler) hotDishes(limit int) []canteenHotDishItem {
	type dishRow struct {
		ID                     uint   `gorm:"column:id"`
		Name                   string `gorm:"column:name"`
		CanteenID              uint   `gorm:"column:canteen_id"`
		CanteenName            string `gorm:"column:canteen_name"`
		CanteenOperatingStatus string `gorm:"column:canteen_operating_status"`
		CoverImage             string `gorm:"column:cover_image"`
		PhotoCount             int    `gorm:"column:photo_count"`
	}
	var rows []dishRow
	if err := h.db.Table("canteen_dishes AS d").
		Joins("JOIN canteens c ON c.id = d.canteen_id AND c.verified = ? AND (c.operating_status = ? OR c.operating_status IS NULL OR c.operating_status = '')", true, models.CanteenOperatingActive).
		Select(`d.id, d.name, d.canteen_id, c.name AS canteen_name, c.operating_status AS canteen_operating_status,
			(SELECT f.path FROM canteen_dish_photos p JOIN files f ON f.id = p.file_id
			 WHERE p.dish_id = d.id AND p.status = ? ORDER BY p.sort_order, p.created_at, p.id LIMIT 1) AS cover_image,
			(SELECT COUNT(*) FROM canteen_dish_photos p WHERE p.dish_id = d.id AND p.status = ?) AS photo_count`,
			models.DishPhotoStatusApproved, models.DishPhotoStatusApproved).
		Where("d.status = ? AND EXISTS (SELECT 1 FROM canteen_dish_photos p WHERE p.dish_id = d.id AND p.status = ?)",
			models.DishStatusActive, models.DishPhotoStatusApproved).
		Scan(&rows).Error; err != nil {
		return []canteenHotDishItem{}
	}

	ids := make([]uint, 0, len(rows))
	for _, row := range rows {
		ids = append(ids, row.ID)
	}
	var summaries []models.CanteenDishRatingSummary
	if len(ids) > 0 {
		_ = h.db.Preload("User").Where("dish_id IN ?", ids).Find(&summaries).Error
	}
	byDish := make(map[uint][]services.DishRatingSample)
	for _, summary := range summaries {
		weight := 1.0
		if summary.User != nil {
			weight = services.ComputeCreditWeight(summary.User.CreditScore)
		}
		byDish[summary.DishID] = append(byDish[summary.DishID], services.DishRatingSample{
			Overall: summary.EffectiveScore,
			Taste:   summary.TasteScore,
			Value:   summary.ValueScore,
			Portion: summary.PortionScore,
			Weight:  weight,
		})
	}

	hot := make([]canteenHotDishItem, 0, len(rows))
	for _, row := range rows {
		agg := services.ComputeDishAggregate(byDish[row.ID])
		hot = append(hot, canteenHotDishItem{
			ID:                     row.ID,
			Name:                   row.Name,
			CanteenID:              row.CanteenID,
			CanteenName:            row.CanteenName,
			CanteenOperatingStatus: row.CanteenOperatingStatus,
			CoverImage:             row.CoverImage,
			PhotoCount:             row.PhotoCount,
			AverageScore:           agg.AverageScore,
			ReviewerCount:          agg.ReviewerCount,
		})
	}
	sort.SliceStable(hot, func(i, j int) bool {
		if hot[i].ReviewerCount != hot[j].ReviewerCount {
			return hot[i].ReviewerCount > hot[j].ReviewerCount
		}
		if hot[i].AverageScore != hot[j].AverageScore {
			return hot[i].AverageScore > hot[j].AverageScore
		}
		return hot[i].PhotoCount > hot[j].PhotoCount
	})
	if len(hot) > limit {
		hot = hot[:limit]
	}
	return hot
}

func pickPhoto(pool []canteenPhotoItem, seen map[uint]int, lastCanteen uint, lastType string) *canteenFeedItem {
	for i := range pool {
		p := pool[i]
		if seen[p.CanteenID] >= 1 || lastCanteen == p.CanteenID {
			continue
		}
		return &canteenFeedItem{
			ID:              fmt.Sprintf("recent_photo:%d", pool[i].DishID),
			Type:            "recent_photo",
			CanteenID:       p.CanteenID,
			CanteenName:     p.CanteenName,
			OperatingStatus: models.CanteenOperatingActive,
			DishID:          p.DishID,
			DishName:        p.DishName,
			Title:           "最近实拍",
			Reason:          p.DishName + " · 看看最近实际卖相",
			Images:          []string{p.Image},
			CreatedAt:       p.CreatedAt.Format("2006-01-02 15:04:05"),
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

func trimFloat(v float64, digits int) string {
	return strconv.FormatFloat(v, 'f', digits, 64)
}

func itoa(v int) string {
	return strconv.Itoa(v)
}

// sumRecentReviewCounts 汇总近 7 天到店评价事件，用于兼容旧首页字段。
// 该字段不是今日按用户-食堂去重后的有效评价人数，不参与评分。
func sumRecentReviewCounts(counts map[uint]int64) int {
	total := 0
	for _, count := range counts {
		if count > 0 {
			total += int(count)
		}
	}
	return total
}

// GetHome 食堂发现首页聚合。GET /api/canteens/home
func (h *CanteenHandler) GetHome(c *gin.Context) {
	// 首页响应新增 recent_reviews 与今日去重样本计数，单独升级缓存键避免命中旧结构。
	cacheKey := "home:v3"
	generation := canteenDiscoveryCache.Generation()
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
		score := services.BayesianRatingScore(r.AverageStar, r.EffectiveSample, mean, services.BayesianPriorWeight)
		entries = append(entries, canteenRankingEntry{canteenStatsRow: r, RankingScore: score})
	}
	sortRanking(entries, "composite")

	// 批量拉取近 30 天评价标签和近 7 天评价数，一次性查询避免 N+1 与重复查询
	tagMap := h.batchAggregateSummaryTags(summaryTagDays, 3)
	recentCounts := h.batchRecentReviewCounts(7)

	// Hero：综合分最高的「有评价」食堂。
	var hero *canteenFeedItem
	for _, e := range entries {
		if e.RatingCount == 0 {
			continue
		}
		tags := takeSummaryTags(tagMap[e.ID], 3)
		tagNames := make([]string, 0, len(tags))
		for _, t := range tags {
			tagNames = append(tagNames, t.Name)
		}
		heroItem := &canteenFeedItem{
			ID:                fmt.Sprintf("recommended_store:%d:v1", e.ID),
			Type:              "recommended_store",
			CanteenID:         e.ID,
			CanteenName:       e.Name,
			OperatingStatus:   e.OperatingStatus,
			Image:             e.Image,
			Title:             "综合推荐",
			Reason:            buildFeedReason(tags, e.AverageStar, e.RatingCount),
			RankingScore:      services.BayesianScoreTo100(e.RankingScore),
			AverageStar:       e.AverageStar,
			RatingCount:       e.RatingCount,
			Tags:              tagNames,
			DimensionScores:   e.DimensionScores,
			ReviewerCount:     e.ReviewerCount,
			VisitReviewCount:  e.VisitReviewCount,
			RecentReviewCount: int(recentCounts[e.ID]),
		}
		hero = heroItem
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
		top = topItem{ID: entries[0].ID, Name: entries[0].Name, RankingScore: services.BayesianScoreTo100(entries[0].RankingScore)}
	}
	rankingEntry := gin.H{
		"top":   top,
		"total": rankTotal,
	}

	// 信息流排除 Hero 已展示的食堂，避免同店重复刷屏，也避免首页 Hero(同一 tag) 冲突。
	feedEntries := entries
	if hero != nil {
		feedEntries = removeCanteen(entries, hero.CanteenID)
	}
	feed := h.BuildHomeFeed(feedEntries, mean, 8, recentCounts, tagMap)
	hotDishes := h.hotDishes(4)
	recentReviews := h.loadRecentHomeReviews(5)

	resp := gin.H{
		"generated_at":                   time.Now(),
		"hero":                           hero,
		"ranking_entry":                  rankingEntry,
		"feed":                           feed,
		"hot_dishes":                     hotDishes,
		"recent_reviews":                 recentReviews,
		"today_effective_reviewer_count": h.todayEffectiveReviewerCount(),
		"recent_effective_review_count":  sumRecentReviewCounts(recentCounts),
	}
	canteenDiscoveryCache.SetIfGeneration(cacheKey, resp, generation)
	c.JSON(200, resp)
}
