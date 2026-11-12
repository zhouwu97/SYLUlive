package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"gorm.io/gorm"

	"github.com/gin-gonic/gin"
)

// canteenDiscoveryCache 首页与排行页的共享内存缓存（TTL 60s，变更时主动失效）。
var canteenDiscoveryCache = services.NewCanteenDiscoveryCache(60 * time.Second)

// summaryTagDays 标签聚合的默认回溯天数。
const summaryTagDays = 30

// batchAggregateSummaryTags 批量拉取近 days 天内评价标签并在 Go 内存中按食堂分组聚合 topK（只留白名单）。
// 消除按店 N+1 查询。
func (h *CanteenHandler) batchAggregateSummaryTags(days int, topK int) (map[uint][]services.SummaryTag, error) {
	if days <= 0 {
		days = summaryTagDays
	}
	since := time.Now().AddDate(0, 0, -days)
	type ratingTagRow struct {
		CanteenID uint   `gorm:"column:canteen_id"`
		Tags      string `gorm:"column:tags"`
	}
	// 查询失败必须上报：返回空 map 会让榜单标签静默变空，而接口仍然 200。
	var rows []ratingTagRow
	if err := h.db.Table("canteen_review_events AS e").
		Select("e.canteen_id, e.tags").
		Where("e.status = ? AND e.score_version >= ? AND e.created_at >= ?", models.ReviewEventStatusActive, 2, since).
		Where("e.tags IS NOT NULL AND e.tags <> '' AND e.tags <> '[]'").
		Scan(&rows).Error; err != nil {
		return nil, err
	}
	var legacyRows []ratingTagRow
	if err := h.db.Table("canteen_ratings AS r").
		Select("r.canteen_id, r.tags").
		Where("(r.status = ? OR r.status IS NULL OR r.status = '') AND r.created_at >= ?", models.ReviewEventStatusActive, since).
		Where("r.tags IS NOT NULL AND r.tags <> '' AND r.tags <> '[]'").
		Where("NOT EXISTS (SELECT 1 FROM canteen_review_events e WHERE e.canteen_id = r.canteen_id AND e.user_id = r.user_id AND e.status = ? AND (e.score_version >= ? OR e.score_version = ?))", models.ReviewEventStatusActive, 2, 0).
		Scan(&legacyRows).Error; err != nil {
		return nil, err
	}
	rows = append(rows, legacyRows...)

	canteenRaws := make(map[uint][]string, len(rows))
	for _, r := range rows {
		canteenRaws[r.CanteenID] = append(canteenRaws[r.CanteenID], r.Tags)
	}

	result := make(map[uint][]services.SummaryTag, len(canteenRaws))
	for cid, raws := range canteenRaws {
		result[cid] = services.AggregateSummaryTagsInMemory(raws, topK)
	}
	var overrides []models.Canteen
	if err := h.db.Select("id", "display_tags").Where("display_tags IS NOT NULL").Find(&overrides).Error; err != nil {
		return nil, err
	}
	for _, canteen := range overrides {
		var keys []string
		if json.Unmarshal([]byte(*canteen.DisplayTags), &keys) != nil {
			continue
		}
		tags := make([]services.SummaryTag, 0, len(keys))
		for _, key := range keys {
			if name, ok := services.CanteenTagName[key]; ok {
				tags = append(tags, services.SummaryTag{Key: key, Name: name})
			}
		}
		if topK > 0 && len(tags) > topK {
			tags = tags[:topK]
		}
		result[canteen.ID] = tags
	}
	return result, nil
}

// aggregateSummaryTags 单店查询包装（向前兼容）。
func (h *CanteenHandler) aggregateSummaryTags(canteenID uint, days int, topK int) ([]services.SummaryTag, error) {
	if days <= 0 {
		days = summaryTagDays
	}
	since := time.Now().AddDate(0, 0, -days)
	var raws []string
	if err := h.db.Table("canteen_review_events AS e").
		Where("e.canteen_id = ? AND e.status = ? AND e.score_version >= ? AND e.created_at >= ?", canteenID, models.ReviewEventStatusActive, 2, since).
		Where("e.tags IS NOT NULL AND e.tags <> '' AND e.tags <> '[]'").
		Pluck("e.tags", &raws).Error; err != nil {
		return nil, err
	}
	var legacyRaws []string
	if err := h.db.Table("canteen_ratings AS r").
		Where("r.canteen_id = ? AND (r.status = ? OR r.status IS NULL OR r.status = '') AND r.created_at >= ?", canteenID, models.ReviewEventStatusActive, since).
		Where("r.tags IS NOT NULL AND r.tags <> '' AND r.tags <> '[]'").
		Where("NOT EXISTS (SELECT 1 FROM canteen_review_events e WHERE e.canteen_id = r.canteen_id AND e.user_id = r.user_id AND e.status = ? AND (e.score_version >= ? OR e.score_version = ?))", models.ReviewEventStatusActive, 2, 0).
		Pluck("r.tags", &legacyRaws).Error; err != nil {
		return nil, err
	}
	raws = append(raws, legacyRaws...)
	return services.AggregateSummaryTagsInMemory(raws, topK), nil
}

// batchRecentReviewCounts 批量统计所有食堂近 days 天内的评价事件数（消除按店 N+1）。
func (h *CanteenHandler) batchRecentReviewCounts(days int) (map[uint]int64, error) {
	type countRow struct {
		CanteenID uint  `gorm:"column:canteen_id"`
		Cnt       int64 `gorm:"column:cnt"`
	}
	var rows []countRow
	since := time.Now().AddDate(0, 0, -days)
	// 同上：失败即上报，避免"评价数静默变 0"被前端当成真的没有评价。
	if err := h.db.Table("canteen_review_events").
		Select("canteen_id, COUNT(*) as cnt").
		Where("status = ? AND score_version >= ? AND created_at >= ?", models.ReviewEventStatusActive, 2, since).
		Group("canteen_id").
		Scan(&rows).Error; err != nil {
		return nil, err
	}
	var legacyRows []countRow
	if err := h.db.Table("canteen_ratings AS r").
		Select("r.canteen_id, COUNT(*) as cnt").
		Where("(r.status = ? OR r.status IS NULL OR r.status = '') AND r.created_at >= ?", models.ReviewEventStatusActive, since).
		Where("NOT EXISTS (SELECT 1 FROM canteen_review_events e WHERE e.canteen_id = r.canteen_id AND e.user_id = r.user_id AND e.status = ? AND (e.score_version >= ? OR e.score_version = ?))", models.ReviewEventStatusActive, 2, 0).
		Group("r.canteen_id").
		Scan(&legacyRows).Error; err != nil {
		return nil, err
	}
	rows = append(rows, legacyRows...)

	counts := make(map[uint]int64, len(rows))
	for _, r := range rows {
		counts[r.CanteenID] += r.Cnt
	}
	return counts, nil
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
// rating 倒序展示：从低分开始往下，星级低→高、同星级评价人数少→多。
//
// scope=current（默认）只排营业中的商家，下架商家不占名次，现有商家的名次随之重排；
// scope=all 是“全部排名”：已下架商家按真实评分一起参与，并标注下架状态。
func (h *CanteenHandler) GetRankings(c *gin.Context) {
	sortMode := c.DefaultQuery("sort", "composite")
	switch sortMode {
	case "composite", "rating", "review_count":
	default:
		sortMode = "composite"
	}
	scope := c.DefaultQuery("scope", "current")
	if scope != "all" {
		scope = "current"
	}

	cacheKey := "rankings:" + sortMode + ":" + scope
	generation := canteenDiscoveryCache.Generation()
	if cached, ok := canteenDiscoveryCache.Get(cacheKey); ok {
		c.JSON(200, cached)
		return
	}

	rows, err := h.queryCanteenStats(scope == "all")
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
	sortRankingScoped(entries, sortMode, scope != "all")

	// 批量拉取近 30 天全部评价标签（避免 N+1）：前 3 个用于展示，完整 key 列表供客户端按标签筛选。
	tagMap, tagErr := h.batchAggregateSummaryTags(summaryTagDays, 0)
	if tagErr != nil {
		c.JSON(500, gin.H{"error": "获取排行失败"})
		return
	}

	type item struct {
		Rank int `json:"rank"`
		// Ranked 为 false 表示还没有人评价：rank 只为兼容旧客户端保留，新客户端不显示名次。
		Ranked             bool                  `json:"ranked"`
		ID                 uint                  `json:"id"`
		Name               string                `json:"name"`
		LocationArea       string                `json:"location_area"`
		LocationFloor      string                `json:"location_floor"`
		Image              string                `json:"image"`
		OperatingStatus    string                `json:"operating_status"`
		IsOffline          bool                  `json:"is_offline"`
		AverageStar        float64               `json:"average_star"`
		RatingCount        int                   `json:"rating_count"`
		RankingScore       float64               `json:"ranking_score"`
		Confidence         string                `json:"confidence"`
		DishCount          int                   `json:"dish_count"`
		DishWithPhotoCount int                   `json:"dish_with_photo_count"`
		DishPhotoCount     int                   `json:"dish_photo_count"`
		SummaryTags        []services.SummaryTag `json:"summary_tags"`
		TagKeys            []string              `json:"tag_keys"`
	}
	items := make([]item, 0, len(entries))
	ratedTotal := 0
	for _, e := range entries {
		if e.RatingCount > 0 {
			ratedTotal++
		}
		items = append(items, item{
			Rank:               e.Rank,
			Ranked:             e.RatingCount > 0,
			ID:                 e.ID,
			Name:               e.Name,
			LocationArea:       e.LocationArea,
			LocationFloor:      e.LocationFloor,
			Image:              e.Image,
			OperatingStatus:    e.OperatingStatus,
			IsOffline:          e.IsOffline,
			AverageStar:        e.AverageStar,
			RatingCount:        e.RatingCount,
			RankingScore:       services.BayesianScoreTo100(e.RankingScore),
			Confidence:         services.RatingConfidenceEffective(e.EffectiveSample),
			DishCount:          e.DishCount,
			DishWithPhotoCount: e.DishWithPhotoCount,
			DishPhotoCount:     e.DishPhotoCount,
			SummaryTags:        takeSummaryTags(tagMap[e.ID], 3),
			TagKeys:            summaryTagKeys(tagMap[e.ID]),
		})
	}

	resp := gin.H{
		"items": items,
		"meta": gin.H{
			"sort":         sortMode,
			"scope":        scope,
			"algorithm":    "bayesian",
			"prior_weight": services.BayesianPriorWeight,
			"updated_at":   time.Now(),
			"total":        len(items),
			"rated_total":  ratedTotal,
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
	LocationArea      string             `json:"location_area,omitempty"`
	LocationFloor     string             `json:"location_floor,omitempty"`
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

// summaryTagKeys 返回标签 key 列表（无标签时为空数组而不是 null，方便客户端筛选）。
func summaryTagKeys(tags []services.SummaryTag) []string {
	keys := make([]string, 0, len(tags))
	for _, tag := range tags {
		keys = append(keys, tag.Key)
	}
	return keys
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
) ([]canteenFeedItem, error) {
	if recentCounts == nil {
		queried, err := h.batchRecentReviewCounts(7)
		if err != nil {
			return nil, err
		}
		recentCounts = queried
	}
	if summaryTags == nil {
		queried, err := h.batchAggregateSummaryTags(summaryTagDays, 3)
		if err != nil {
			return nil, err
		}
		summaryTags = queried
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
	return feed, nil
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
			LocationArea:    e.LocationArea,
			LocationFloor:   e.LocationFloor,
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
			LocationArea:    e.LocationArea,
			LocationFloor:   e.LocationFloor,
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
			LocationArea:    e.LocationArea,
			LocationFloor:   e.LocationFloor,
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
	// RecentMentionCount 是近 hotDishRecentDays 天有多少条到店评价提到这道菜。
	RecentMentionCount int `json:"recent_mention_count"`
}

// hotDishRecentDays 是“近期热门”的统计窗口。
const hotDishRecentDays = 30

// hotDishes 热门菜品：只取有真实实拍的 active 菜品，先按近 30 天被评价提到的次数排序
// （真正的“最近大家在吃”），再按打分人数、分数和实拍数兜底。limit<=0 返回全部。
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
			 WHERE p.dish_id = d.id AND p.status = ? ORDER BY p.sort_order, p.created_at DESC, p.id DESC LIMIT 1) AS cover_image,
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
	aggregates := loadDishAggregates(h.db, ids)
	recentMentions := make(map[uint]int, len(ids))
	if len(ids) > 0 {
		var recentRows []struct {
			DishID uint `gorm:"column:dish_id"`
			Count  int  `gorm:"column:count"`
		}
		_ = h.db.Table("canteen_review_event_dishes AS r").
			Joins("JOIN canteen_review_events e ON e.id = r.review_event_id").
			Select("r.dish_id AS dish_id, COUNT(DISTINCT r.review_event_id) AS count").
			Where("r.dish_id IN ? AND e.status = ? AND e.created_at >= ?", ids, models.ReviewEventStatusActive,
				time.Now().AddDate(0, 0, -hotDishRecentDays)).
			Group("r.dish_id").Scan(&recentRows).Error
		for _, row := range recentRows {
			recentMentions[row.DishID] = row.Count
		}
	}

	hot := make([]canteenHotDishItem, 0, len(rows))
	for _, row := range rows {
		agg := aggregates[row.ID]
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
			RecentMentionCount:     recentMentions[row.ID],
		})
	}
	sort.SliceStable(hot, func(i, j int) bool {
		if hot[i].RecentMentionCount != hot[j].RecentMentionCount {
			return hot[i].RecentMentionCount > hot[j].RecentMentionCount
		}
		if hot[i].ReviewerCount != hot[j].ReviewerCount {
			return hot[i].ReviewerCount > hot[j].ReviewerCount
		}
		if hot[i].AverageScore != hot[j].AverageScore {
			return hot[i].AverageScore > hot[j].AverageScore
		}
		return hot[i].PhotoCount > hot[j].PhotoCount
	})
	if limit > 0 && len(hot) > limit {
		hot = hot[:limit]
	}
	return hot
}

// GetHotDishes 首页“热门菜品 · 更多”：全校有实拍的菜品按近期热度分页。
// GET /api/canteens/dishes/hot?offset=0&limit=20
func (h *CanteenHandler) GetHotDishes(c *gin.Context) {
	limit, limitErr := strconv.Atoi(c.DefaultQuery("limit", "20"))
	offset, offsetErr := strconv.Atoi(c.DefaultQuery("offset", "0"))
	if limitErr != nil || limit < 1 || limit > 50 || offsetErr != nil || offset < 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "分页参数无效"})
		return
	}
	const cacheKey = "hot_dishes:v1"
	var all []canteenHotDishItem
	if cached, ok := canteenDiscoveryCache.Get(cacheKey); ok {
		all, _ = cached.([]canteenHotDishItem)
	}
	if all == nil {
		generation := canteenDiscoveryCache.Generation()
		all = h.hotDishes(0)
		canteenDiscoveryCache.SetIfGeneration(cacheKey, all, generation)
	}
	page := []canteenHotDishItem{}
	if offset < len(all) {
		end := len(all)
		if offset+limit < end {
			end = offset + limit
		}
		page = all[offset:end]
	}
	c.JSON(http.StatusOK, gin.H{"items": page, "total": len(all), "has_more": offset+len(page) < len(all)})
}

// loadDishAggregates 一次查询批量计算菜品三维评分聚合（按诚信度加权，每人一个有效样本）。
// 热门菜品和菜品详情共用，保证两处显示的分数一致。
func loadDishAggregates(db *gorm.DB, dishIDs []uint) map[uint]services.DishAggregate {
	result := make(map[uint]services.DishAggregate, len(dishIDs))
	if len(dishIDs) == 0 {
		return result
	}
	var summaries []models.CanteenDishRatingSummary
	if err := db.Preload("User").Where("dish_id IN ?", dishIDs).Find(&summaries).Error; err != nil {
		return result
	}
	latestEventIDs := make([]uint, 0, len(summaries))
	for _, summary := range summaries {
		if summary.LatestReviewEventID != nil {
			latestEventIDs = append(latestEventIDs, *summary.LatestReviewEventID)
		}
	}
	latestAt := make(map[uint]time.Time, len(latestEventIDs))
	if len(latestEventIDs) > 0 {
		var events []models.CanteenDishReviewEvent
		if err := db.Select("id", "created_at").Where("id IN ?", latestEventIDs).Find(&events).Error; err == nil {
			for _, event := range events {
				latestAt[event.ID] = event.CreatedAt
			}
		}
	}
	now := time.Now()
	byDish := make(map[uint][]services.DishRatingSample, len(dishIDs))
	for _, summary := range summaries {
		weight := 1.0
		if summary.User != nil {
			weight = services.ComputeCreditWeight(summary.User.CreditScore)
		}
		// 与商家评分同一套时间衰减：按这位同学最近一次给这道菜打分的时间。
		ratedAt := summary.UpdatedAt
		if summary.LatestReviewEventID != nil {
			if at, ok := latestAt[*summary.LatestReviewEventID]; ok {
				ratedAt = at
			}
		}
		weight *= services.TimeDecayWeight(ratedAt, now)
		byDish[summary.DishID] = append(byDish[summary.DishID], services.DishRatingSample{
			Overall: summary.EffectiveScore,
			Taste:   summary.TasteScore,
			Value:   summary.ValueScore,
			Portion: summary.PortionScore,
			Weight:  weight,
		})
	}
	for dishID, samples := range byDish {
		result[dishID] = services.ComputeDishAggregate(samples)
	}
	return result
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

// heroCandidateLimit 是“今天吃什么”可轮换的候选数。
const heroCandidateLimit = 5

// GetHome 食堂发现首页聚合。GET /api/canteens/home
func (h *CanteenHandler) GetHome(c *gin.Context) {
	// 首页响应新增 recent_reviews 与今日去重样本计数，单独升级缓存键避免命中旧结构。
	cacheKey := "home:v4"
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
	tagMap, tagErr := h.batchAggregateSummaryTags(summaryTagDays, 3)
	if tagErr != nil {
		c.JSON(500, gin.H{"error": "获取首页失败"})
		return
	}
	recentCounts, countErr := h.batchRecentReviewCounts(7)
	if countErr != nil {
		c.JSON(500, gin.H{"error": "获取首页失败"})
		return
	}

	// Hero：综合分最高的「有评价」食堂；同时给出前几名作为“换一家”的候选，
	// 客户端按天轮换默认展示哪一家，用户也可以手动换。
	var hero *canteenFeedItem
	heroCandidates := make([]canteenFeedItem, 0, heroCandidateLimit)
	for _, e := range entries {
		if len(heroCandidates) >= heroCandidateLimit {
			break
		}
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
			LocationArea:      e.LocationArea,
			LocationFloor:     e.LocationFloor,
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
		if hero == nil {
			hero = heroItem
		}
		heroCandidates = append(heroCandidates, *heroItem)
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
	ratedTotal := 0
	for _, e := range entries {
		if e.RatingCount > 0 {
			ratedTotal++
		}
	}
	rankingEntry := gin.H{
		"top":   top,
		"total": rankTotal,
		// rated_total 只数有人评价的店：没人评价的店不占名次，首页按它显示“第 1 / N”。
		"rated_total": ratedTotal,
	}

	// 信息流排除 Hero 已展示的食堂，避免同店重复刷屏，也避免首页 Hero(同一 tag) 冲突。
	feedEntries := entries
	if hero != nil {
		feedEntries = removeCanteen(entries, hero.CanteenID)
	}
	feed, feedErr := h.BuildHomeFeed(feedEntries, mean, 8, recentCounts, tagMap)
	if feedErr != nil {
		c.JSON(500, gin.H{"error": "获取首页失败"})
		return
	}
	hotDishes := h.hotDishes(4)
	recentReviews := h.loadRecentHomeReviews(5)

	resp := gin.H{
		"generated_at":                   time.Now(),
		"hero":                           hero,
		"hero_candidates":                heroCandidates,
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
