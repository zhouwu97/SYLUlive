package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

type CanteenHandler struct {
	db *gorm.DB
	// disableTimeDecay 只给上线前的排名对比预览使用，线上请求始终开启时间衰减。
	disableTimeDecay bool
}

var errCanteenOffline = errors.New("canteen_offline")

// canteenSubmissionRewardExp 用户提交食堂审核通过后的一次性经验奖励。
// 下架/删除时收回，恢复营业时返还，保证经验与“店铺是否公开在列”对称。
const canteenSubmissionRewardExp = 10

// lockActiveCanteen 在写入事务内锁定并校验营业状态。
// 事务外的预检查只能改善错误提示，不能防止“下架”和“提交”并发穿透。
func lockActiveCanteen(tx *gorm.DB, canteenID uint) (models.Canteen, error) {
	var canteen models.Canteen
	if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
		Where("id = ? AND verified = ?", canteenID, true).
		First(&canteen).Error; err != nil {
		return canteen, err
	}
	canteen.NormalizeOperatingStatus()
	if canteen.IsOffline {
		return canteen, errCanteenOffline
	}
	return canteen, nil
}

func NewCanteenHandler(db *gorm.DB) *CanteenHandler {
	return &CanteenHandler{db: db}
}

func (h *CanteenHandler) ensureCanteenOperatingActive(c *gin.Context, canteenID uint) bool {
	var canteen models.Canteen
	if err := h.db.Select("id", "verified", "operating_status").First(&canteen, canteenID).Error; err != nil || !canteen.Verified {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return false
	}
	canteen.NormalizeOperatingStatus()
	if canteen.IsOffline {
		c.JSON(http.StatusConflict, gin.H{"code": "canteen_offline", "error": "该店当前已下架，暂不能发布新的评价"})
		return false
	}
	return true
}

// validCanteenTags 食堂评价体验标签白名单
var validCanteenTags = map[string]string{
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

// canteenTagOrder 是体验标签的固定展示顺序；validCanteenTags 是 map，不能直接用于下发。
var canteenTagOrder = []string{
	"taste_good", "portion_enough", "price_fair", "serving_fast", "queue_long",
	"recommended_window", "clean", "service_warm", "environment_clean", "good_value",
}

// GetMeta 下发食堂模块的可选项（位置区域、楼层、体验标签），客户端不再各自写死。
// 新增食堂区域只需改服务端 models.CanteenLocationAreas。
// GET /api/canteens/meta
func (h *CanteenHandler) GetMeta(c *gin.Context) {
	tags := make([]gin.H, 0, len(canteenTagOrder))
	for _, key := range canteenTagOrder {
		if label, ok := validCanteenTags[key]; ok {
			tags = append(tags, gin.H{"key": key, "label": label})
		}
	}
	c.JSON(http.StatusOK, gin.H{
		"location_areas":  models.CanteenLocationAreas,
		"location_floors": models.CanteenLocationFloors,
		"review_tags":     tags,
	})
}

// canteenStatsRow 食堂聚合统计行（GetList / GetRankings / GetHome 共用）。
// RankingScore 与 Rank 由调用方基于全局均值（globalMean）在 Go 内计算。
//
// 注意：排序与评分计算全部放在 Go 层，而不是 SQL。
// 历史教训：把「全校平均分 globalMean」写成 SQL 嵌套子查询，在外层 GROUP BY 下作为
// 算术操作数求值时，SQLite 会返回 NULL/0 导致公式退化为 (n/(n+m))*R，顺序失真。
// Go 层计算对 SQLite/PostgreSQL 行为一致、可单元测试、可解释。
type canteenStatsRow struct {
	models.Canteen
	RatingCount        int                `json:"rating_count"`
	AverageStar        float64            `json:"average_star"`
	ReviewerCount      int                `json:"reviewer_count"`
	VisitReviewCount   int                `json:"visit_review_count"`
	EffectiveSample    float64            `json:"-"`
	DimensionScores    map[string]float64 `gorm:"-" json:"dimension_scores,omitempty"`
	DishCount          int                `json:"dish_count"`
	DishWithPhotoCount int                `json:"dish_with_photo_count"`
	DishPhotoCount     int                `json:"dish_photo_count"`
	RankingScore       float64            `json:"ranking_score"`
}

// canteenRankingEntry 一条可排名的食堂项（含计算出的 Bayesian score 与 rank）。
type canteenRankingEntry struct {
	canteenStatsRow
	RankingScore float64
	Rank         int
}

// queryCanteenStats 拉取全部 verified 食堂的聚合统计。
// 终端尾部保留一个稳定次序（created_at DESC, id DESC），供排序同分时作最后 tie-break。
func (h *CanteenHandler) queryCanteenStats(includeOffline ...bool) ([]canteenStatsRow, error) {
	return h.queryCanteenStatsFor(nil, len(includeOffline) > 0 && includeOffline[0])
}

// queryCanteenStatsFor 只统计 ids 指定的食堂（nil 表示全部）。详情页只需要一家店的
// 摘要，不能为此把全校所有店和所有评分都扫一遍。
func (h *CanteenHandler) queryCanteenStatsFor(ids []uint, includeOffline bool) ([]canteenStatsRow, error) {
	var rows []canteenStatsRow
	// 独立聚合子查询（rating_stats / dish_stats），避免 JOIN 膨胀污染 COUNT。
	// 不再内嵌 globalMean 子查询（SQLite 算术语境陷阱，见 canteenStatsRow 注释）。
	query := h.db.Table("canteens").
		Select(`canteens.*,
			COALESCE(rs.rating_count, 0) as rating_count,
			COALESCE(rs.average_star, 0) as average_star,
			COALESCE(ds.dish_count, 0) as dish_count,
			COALESCE(ds.dish_with_photo_count, 0) as dish_with_photo_count,
			COALESCE(ds.dish_photo_count, 0) as dish_photo_count`).
		Joins(`LEFT JOIN (
			SELECT canteen_id, COUNT(*) as rating_count, AVG(CAST(star AS FLOAT)) as average_star
			FROM canteen_ratings
			WHERE status = 'active' OR status IS NULL OR status = ''
			GROUP BY canteen_id
		) rs ON rs.canteen_id = canteens.id`).
		Joins(`LEFT JOIN (
			SELECT d.canteen_id,
				COUNT(DISTINCT d.id) as dish_count,
				COUNT(DISTINCT CASE WHEN p.id IS NOT NULL THEN d.id END) as dish_with_photo_count,
				COUNT(p.id) as dish_photo_count
			FROM canteen_dishes d
			LEFT JOIN canteen_dish_photos p ON p.dish_id = d.id AND p.status = 'approved'
			WHERE d.status = 'active'
			GROUP BY d.canteen_id
		) ds ON ds.canteen_id = canteens.id`).
		Group("canteens.id, rs.rating_count, rs.average_star, ds.dish_count, ds.dish_with_photo_count, ds.dish_photo_count").
		Order("canteens.created_at DESC, canteens.id DESC")
	if ids != nil {
		if len(ids) == 0 {
			return rows, nil
		}
		query = query.Where("canteens.id IN ?", ids)
	}
	if includeOffline {
		query = query.Where("canteens.verified = ?", true)
	} else {
		query = query.Where("canteens.verified = ? AND (canteens.operating_status = ? OR canteens.operating_status IS NULL OR canteens.operating_status = '')", true, models.CanteenOperatingActive)
	}
	err := query.Scan(&rows).Error
	if err != nil {
		return rows, err
	}
	for i := range rows {
		rows[i].NormalizeOperatingStatus()
	}
	h.hydrateV2CanteenScores(rows, ids != nil)
	return rows, nil
}

// hydrateV2CanteenScores 将每个用户的有效摘要在 Go 层按诚信度聚合。
// 这样旧 summary 仍可作为 Legacy Star 使用，新事件不会因 SQL 方言差异丢失权重。
func (h *CanteenHandler) hydrateV2CanteenScores(rows []canteenStatsRow, onlyTheseRows bool) {
	if len(rows) == 0 {
		return
	}
	query := h.db.Preload("User").Where("(status = ? OR status IS NULL OR status = '')", "active")
	if onlyTheseRows {
		ids := make([]uint, 0, len(rows))
		for _, row := range rows {
			ids = append(ids, row.ID)
		}
		query = query.Where("canteen_id IN ?", ids)
	}
	var ratings []models.CanteenRating
	if err := query.Find(&ratings).Error; err != nil {
		return
	}
	// 时间衰减按“这位同学在这家店最近一次评价”的时间算，一次 IN 查询取回。
	latestEventIDs := make([]uint, 0, len(ratings))
	for _, rating := range ratings {
		if rating.LatestReviewEventID != nil {
			latestEventIDs = append(latestEventIDs, *rating.LatestReviewEventID)
		}
	}
	latestAt := make(map[uint]time.Time, len(latestEventIDs))
	if len(latestEventIDs) > 0 {
		var events []models.CanteenReviewEvent
		if err := h.db.Select("id", "created_at").Where("id IN ?", latestEventIDs).Find(&events).Error; err == nil {
			for _, event := range events {
				latestAt[event.ID] = event.CreatedAt
			}
		}
	}
	now := time.Now()
	samplesByCanteen := make(map[uint][]services.UserRatingSample)
	visitsByCanteen := make(map[uint]int)
	for _, rating := range ratings {
		if rating.ReviewEventCount > 0 {
			visitsByCanteen[rating.CanteenID] += rating.ReviewEventCount
		} else {
			visitsByCanteen[rating.CanteenID]++
		}
		sample := services.UserRatingSample{Overall: float64(rating.Star), Weight: 1}
		if rating.EffectiveScore > 0 && rating.ScoreVersion >= 2 {
			sample.Overall = rating.EffectiveScore
			sample.Taste = rating.TasteScore
			sample.Value = rating.ValueScore
			sample.Queue = rating.QueueScore
			sample.Hygiene = rating.HygieneScore
			sample.Service = rating.ServiceScore
			sample.HasDimensions = true
		}
		if rating.User != nil {
			sample.Weight = services.ComputeCreditWeight(rating.User.CreditScore)
		}
		reviewedAt := rating.CreatedAt
		if rating.LatestReviewEventID != nil {
			if at, ok := latestAt[*rating.LatestReviewEventID]; ok {
				reviewedAt = at
			}
		}
		if !h.disableTimeDecay {
			sample.Weight *= services.TimeDecayWeight(reviewedAt, now)
		}
		samplesByCanteen[rating.CanteenID] = append(samplesByCanteen[rating.CanteenID], sample)
	}
	for i := range rows {
		aggregate := services.ComputeCanteenAggregate(samplesByCanteen[rows[i].ID])
		if aggregate.ReviewerCount == 0 {
			continue
		}
		rows[i].RatingCount = aggregate.ReviewerCount
		rows[i].ReviewerCount = aggregate.ReviewerCount
		rows[i].EffectiveSample = aggregate.EffectiveSample
		rows[i].AverageStar = aggregate.AverageScore
		rows[i].VisitReviewCount = visitsByCanteen[rows[i].ID]
		rows[i].DimensionScores = map[string]float64{
			"taste": aggregate.TasteScore, "value": aggregate.ValueScore,
			"queue": aggregate.QueueScore, "hygiene": aggregate.HygieneScore,
			"service": aggregate.ServiceScore,
		}
	}
}

// globalMeanStars 计算全体「有评价」食堂的平均星级（Bayesian 公式里的 C）。
// 与原始 SQL 语义一致：从按食堂分组的平均分再取一次均值；无评价食堂不参与。
func globalMeanStars(rows []canteenStatsRow) float64 {
	var sum float64
	var effectiveSample float64
	for _, r := range rows {
		if r.RatingCount > 0 && isCanteenOperatingActive(r.OperatingStatus) {
			weight := r.EffectiveSample
			if weight <= 0 {
				weight = float64(r.RatingCount)
			}
			sum += r.AverageStar * weight
			effectiveSample += weight
		}
	}
	if effectiveSample == 0 {
		return 0
	}
	return sum / effectiveSample
}

func isCanteenOperatingActive(status string) bool {
	return status == "" || status == models.CanteenOperatingActive
}

func isCanteenReviewSchemaMissing(err error) bool {
	if err == nil {
		return false
	}
	lower := strings.ToLower(err.Error())
	return strings.Contains(lower, "no such table") || strings.Contains(lower, "does not exist")
}

// sortRanking 按 mode 策略排序并赋 rank，tie-break 稳定（都退到 rating_count → average → created_at → id）。
// rating 模式倒序展示：从低分开始往下，星级低→高、同星级评价人数少→多；composite / review_count 仍高分在前。
func sortRanking(entries []canteenRankingEntry, mode string) {
	less := func(a, b canteenRankingEntry) bool {
		aActive, bActive := isCanteenOperatingActive(a.OperatingStatus), isCanteenOperatingActive(b.OperatingStatus)
		if aActive != bActive {
			return aActive
		}
		var ka, kb float64
		var na, nb int
		ratingAsc := mode == "rating"
		switch mode {
		case "rating":
			ka, kb = a.AverageStar, b.AverageStar
			na, nb = a.RatingCount, b.RatingCount
		case "review_count":
			na, nb = a.RatingCount, b.RatingCount
			ka, kb = a.AverageStar, b.AverageStar
		default: // composite（Bayesian）
			ka, kb = a.RankingScore, b.RankingScore
			na, nb = a.RatingCount, b.RatingCount
		}
		// 无评价食堂按主键 0 的分值恒低，天然置后；但评分/评价数排序时避免 0 分店误排，
		// 统一再以「有无评价」为第一优先。
		aRated, bRated := a.RatingCount > 0, b.RatingCount > 0
		if aRated != bRated {
			return aRated
		}
		if ka != kb {
			if ratingAsc {
				return ka < kb
			}
			return ka > kb
		}
		if na != nb {
			if ratingAsc {
				return na < nb
			}
			return na > nb
		}
		if a.AverageStar != b.AverageStar {
			return a.AverageStar > b.AverageStar
		}
		if !a.CreatedAt.Equal(b.CreatedAt) {
			return a.CreatedAt.After(b.CreatedAt)
		}
		return a.ID < b.ID
	}
	// stable sort：为同分保持 created_at 稳定次序。
	sort.SliceStable(entries, func(i, j int) bool { return less(entries[i], entries[j]) })
	for i := range entries {
		entries[i].Rank = i + 1
	}
}

// canteenNameMatches 按店名做不区分大小写的包含匹配；空查询视为全部命中。
func canteenNameMatches(name, normalizedQuery string) bool {
	return normalizedQuery == "" || strings.Contains(strings.ToLower(name), normalizedQuery)
}

// canteenMatchesQuery 搜索同时匹配店名、位置（“二食堂”“一食堂二楼”）和体验标签（“出餐快”）。
func canteenMatchesQuery(row canteenStatsRow, normalizedQuery string, tags []services.SummaryTag) bool {
	if canteenNameMatches(row.Name, normalizedQuery) {
		return true
	}
	compactQuery := strings.ReplaceAll(normalizedQuery, " ", "")
	location := row.LocationArea + row.LocationFloor
	if location != "" && (strings.Contains(location, compactQuery) ||
		(row.LocationArea != "" && compactQuery == row.LocationArea) ||
		(row.LocationFloor != "" && compactQuery == row.LocationFloor)) {
		return true
	}
	for _, tag := range tags {
		if tag.Name != "" && strings.Contains(tag.Name, compactQuery) {
			return true
		}
	}
	return false
}

// GetList 获取食堂列表（Bayesian 综合排序，无评价食堂置后）。兼容旧客户端字段。
//
// 可选参数均不传时行为与旧版一致（全部已审核食堂，含已下架）：
//   - q：按店名过滤；
//   - status=active：只返回营业中的食堂；
//   - limit / page：传 limit 时才分页（limit 1~100，page 从 1 开始），仍返回顶层数组。
func (h *CanteenHandler) GetList(c *gin.Context) {
	activeOnly := c.Query("status") == models.CanteenOperatingActive
	rows, err := h.queryCanteenStats(!activeOnly)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取食堂列表失败"})
		return
	}
	mean := globalMeanStars(rows)
	entries := make([]canteenRankingEntry, 0, len(rows))
	for _, r := range rows {
		score := float64(0)
		if isCanteenOperatingActive(r.OperatingStatus) {
			score = services.BayesianRatingScore(r.AverageStar, r.EffectiveSample, mean, services.BayesianPriorWeight)
		}
		entries = append(entries, canteenRankingEntry{canteenStatsRow: r, RankingScore: score})
	}
	sortRanking(entries, "composite")

	// 返回结构保持旧客户端兼容（顶层数组，新增 ranking_score 字段旧端忽略）。
	normalizedQuery := strings.ToLower(strings.TrimSpace(c.Query("q")))
	// 与 App 搜索同一套匹配：店名、位置和近 30 天体验标签；没有关键词时不必聚合标签。
	var tagMap map[uint][]services.SummaryTag
	if normalizedQuery != "" {
		var tagErr error
		if tagMap, tagErr = h.batchAggregateSummaryTags(summaryTagDays, 0); tagErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取食堂列表失败"})
			return
		}
	}
	out := make([]canteenStatsRow, 0, len(entries))
	for _, e := range entries {
		row := e.canteenStatsRow
		if normalizedQuery != "" && !canteenMatchesQuery(row, normalizedQuery, tagMap[row.ID]) {
			continue
		}
		if isCanteenOperatingActive(row.OperatingStatus) {
			row.RankingScore = services.BayesianScoreTo100(e.RankingScore)
		} else {
			row.RankingScore = 0
		}
		out = append(out, row)
	}
	if rawLimit := strings.TrimSpace(c.Query("limit")); rawLimit != "" {
		limit, limitErr := strconv.Atoi(rawLimit)
		page, pageErr := strconv.Atoi(c.DefaultQuery("page", "1"))
		if limitErr != nil || limit < 1 || limit > 100 || pageErr != nil || page < 1 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "分页参数无效"})
			return
		}
		// 先按页数比较再相乘，超大 page 不会溢出成负下标。
		if page-1 > len(out)/limit || (page-1)*limit >= len(out) {
			out = out[:0]
		} else {
			start := (page - 1) * limit
			end := start + limit
			if end > len(out) {
				end = len(out)
			}
			out = out[start:end]
		}
	}
	c.JSON(http.StatusOK, out)
}

// canteenSearchRow 在食堂统计上附带它在综合排行中的真实名次。
type canteenSearchRow struct {
	canteenStatsRow
	Rank int `json:"rank"`
}

// Search 返回食堂和菜品的一级发现结果。菜品命中时同时携带所属食堂，客户端可直接
// 进入菜品详情，不必先猜测食堂再做一次列表过滤。
// 食堂命中按综合排行排序，rank 与 /rankings?sort=composite 的名次一致；
// 客户端只能展示 rank，不能把结果下标当作排行名次。
// GET /api/canteens/search?q=...
func (h *CanteenHandler) Search(c *gin.Context) {
	query := strings.TrimSpace(c.Query("q"))
	if query == "" {
		c.JSON(http.StatusOK, gin.H{"canteens": []canteenSearchRow{}, "dishes": []gin.H{}})
		return
	}
	normalizedQuery := strings.ToLower(query)
	rows, err := h.queryCanteenStats()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "搜索食堂失败"})
		return
	}
	mean := globalMeanStars(rows)
	entries := make([]canteenRankingEntry, 0, len(rows))
	for _, r := range rows {
		score := services.BayesianRatingScore(r.AverageStar, r.EffectiveSample, mean, services.BayesianPriorWeight)
		entries = append(entries, canteenRankingEntry{canteenStatsRow: r, RankingScore: score})
	}
	sortRanking(entries, "composite")
	tagMap, tagErr := h.batchAggregateSummaryTags(summaryTagDays, 0)
	if tagErr != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "搜索食堂失败"})
		return
	}
	matchedCanteens := make([]canteenSearchRow, 0, 10)
	for _, e := range entries {
		if !canteenMatchesQuery(e.canteenStatsRow, normalizedQuery, tagMap[e.ID]) {
			continue
		}
		row := e.canteenStatsRow
		row.RankingScore = services.BayesianScoreTo100(e.RankingScore)
		matchedCanteens = append(matchedCanteens, canteenSearchRow{canteenStatsRow: row, Rank: e.Rank})
	}
	type dishSearchRow struct {
		ID                     uint   `json:"id"`
		Name                   string `json:"name"`
		CanteenID              uint   `json:"canteen_id"`
		CanteenName            string `json:"canteen_name"`
		CanteenLocationArea    string `json:"canteen_location_area"`
		CanteenLocationFloor   string `json:"canteen_location_floor"`
		CanteenOperatingStatus string `json:"canteen_operating_status"`
	}
	var dishes []dishSearchRow
	// LIKE 在 PostgreSQL 区分大小写，统一转小写比较，英文菜名也能搜到。
	like := "%" + normalizedQuery + "%"
	if err := h.db.Table("canteen_dishes AS d").
		Select("d.id, d.name, d.canteen_id, c.name AS canteen_name, c.location_area AS canteen_location_area, c.location_floor AS canteen_location_floor, c.operating_status AS canteen_operating_status").
		Joins("JOIN canteens c ON c.id = d.canteen_id").
		Where("d.status = ? AND c.verified = ? AND (c.operating_status = ? OR c.operating_status IS NULL OR c.operating_status = '') AND (LOWER(d.name) LIKE ? OR LOWER(d.normalized_name) LIKE ?)", models.DishStatusActive, true, models.CanteenOperatingActive, like, like).
		Order("d.name ASC, d.id ASC").Limit(30).Find(&dishes).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "搜索菜品失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"canteens": matchedCanteens, "dishes": dishes})
}

// GetDetail 食堂详情（含评价列表）
func (h *CanteenHandler) GetDetail(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, strconv.IntSize)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	var canteen models.Canteen
	if err := h.db.First(&canteen, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}
	if !canteen.Verified {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}

	reviewSort := c.DefaultQuery("review_sort", "best")
	reviewFilter := c.DefaultQuery("review_filter", "all")
	viewerID := uint(0)
	if rawUserID, exists := c.Get("user_id"); exists {
		userID, ok := rawUserID.(uint)
		if !ok || userID == 0 {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "登录状态无效"})
			return
		}
		viewerID = userID
	}

	reviewSort, reviewFilter = normalizeDisplayReviewParams(reviewSort, reviewFilter)
	// compact=1 是新客户端的轻量模式：不再重复返回旧 ratings / reviews 列表，
	// 混合评价流只返回第一页，其余通过 /:id/display-reviews 分页拉取。
	compact := c.Query("compact") == "1"
	displayReviews, ratings, displayErr := h.buildDisplayReviewsForViewer(canteen, reviewSort, reviewFilter, viewerID)
	if displayErr != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取评价列表失败"})
		return
	}

	var count int64
	var avg float64
	h.db.Model(&models.CanteenRating{}).Where("canteen_id = ? AND (status = ? OR status IS NULL OR status = '')", id, models.ReviewEventStatusActive).Count(&count)
	if count > 0 {
		h.db.Model(&models.CanteenRating{}).Where("canteen_id = ? AND (status = ? OR status IS NULL OR status = '')", id, models.ReviewEventStatusActive).Select("AVG(CAST(star AS FLOAT))").Scan(&avg)
	}

	var myRating *models.CanteenRating
	var myLatestReview map[string]interface{}
	reviewAction := map[string]interface{}{
		// 未登录时仍展示“添加评价”入口，客户端点击后负责引导登录；
		// 登录用户的编辑状态再由下方按账号覆盖；新评价允许立即重复发布。
		"can_create":       true,
		"can_edit_latest":  false,
		"latest_review_id": nil,
	}
	if viewerID != 0 {
		uid := viewerID
		type ratingDishRecRow struct {
			RatingID uint   `gorm:"column:rating_id"`
			DishName string `gorm:"column:dish_name"`
		}
		var rating models.CanteenRating
		if err := h.db.Where("canteen_id = ? AND user_id = ? AND (status = ? OR status IS NULL OR status = '')", id, uid, models.ReviewEventStatusActive).First(&rating).Error; err == nil {
			var user models.User
			if err := h.db.Select("nickname, student_id, avatar").First(&user, rating.UserID).Error; err == nil {
				rating.UserName = user.Nickname
				rating.UserAvatar = user.Avatar
			}
			var myRecRows []ratingDishRecRow
			if err := h.db.Table("canteen_rating_dish_recommendations").
				Select("rating_id, dish_name").
				Where("rating_id = ?", rating.ID).
				Order("id ASC").
				Find(&myRecRows).Error; err == nil {
				for _, row := range myRecRows {
					rating.RecommendedDishNames = append(rating.RecommendedDishNames, row.DishName)
				}
			}
			myRating = &rating
		}
		if latest, latestErr := h.loadMyLatestReviewPayload(uint(id), uid); latestErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取我的新版评价失败"})
			return
		} else {
			myLatestReview = latest
		}
		if action, actionErr := h.buildReviewAction(uint(id), uid); actionErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取评价操作状态失败"})
			return
		} else {
			reviewAction = action
		}
	}
	// V2 评价流与 /reviews 共用同一套“先按用户取最新、再筛选、再排序”的语义，
	// 旧 reviews 字段继续保留给旧客户端；compact 模式下新客户端不读它，直接跳过。
	reviews := []models.CanteenReviewEvent{}
	if !compact {
		loaded, reviewsErr := h.loadCanteenReviews(uint(id), reviewSort, reviewFilter, false)
		if reviewsErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取评价列表失败"})
			return
		}
		populateReviewDishNamesForViewer(h.db, loaded, viewerID)
		populateReviewDishPhotosForViewer(h.db, loaded, viewerID)
		if viewerID != 0 {
			populateReviewVotes(h.db, loaded, viewerID)
		}
		reviews = loaded
	}
	canteen.NormalizeOperatingStatus()
	var v2Stats *canteenStatsRow
	if stats, statsErr := h.queryCanteenStatsFor([]uint{uint(id)}, true); statsErr == nil && len(stats) == 1 {
		v2Stats = &stats[0]
	}
	if v2Stats != nil {
		count = int64(v2Stats.RatingCount)
		avg = v2Stats.AverageStar
	}

	responseRatings := ratings
	displayTotal := len(displayReviews)
	if compact {
		responseRatings = []models.CanteenRating{}
		limit := 20
		if parsed, err := strconv.Atoi(c.DefaultQuery("review_limit", "20")); err == nil && parsed > 0 && parsed <= 50 {
			limit = parsed
		}
		if len(displayReviews) > limit {
			displayReviews = displayReviews[:limit]
		}
	}
	c.JSON(http.StatusOK, gin.H{
		"is_favorite":              h.isFavoriteCanteen(viewerID, uint(id)),
		"display_reviews_total":    displayTotal,
		"display_reviews_has_more": len(displayReviews) < displayTotal,
		"canteen":                  canteen,
		"ratings":                  responseRatings,
		"rating_count":             count,
		"average_star":             avg,
		"my_rating":                myRating,
		"my_latest_review":         myLatestReview,
		"review_action":            reviewAction,
		"reviews":                  reviews,
		"display_reviews":          displayReviews,
		"reviewer_count":           count,
		"visit_review_count": func() int {
			if v2Stats == nil {
				return int(count)
			}
			return v2Stats.VisitReviewCount
		}(),
		"dimension_scores": func() map[string]float64 {
			if v2Stats == nil {
				return map[string]float64{}
			}
			return v2Stats.DimensionScores
		}(),
	})
}

// normalizeDisplayReviewParams 把未知的排序/筛选回落到默认值。
func normalizeDisplayReviewParams(sortBy, filter string) (string, string) {
	if sortBy != "latest" {
		sortBy = "best"
	}
	switch filter {
	case "with_image", "high", "low":
	default:
		filter = "all"
	}
	return sortBy, filter
}

// loadLegacyRatingsForDisplay 读取旧版 /rate 评分（含当前用户的投票与推荐菜）。
func (h *CanteenHandler) loadLegacyRatingsForDisplay(canteenID uint, sortBy, filter string, viewerID uint) ([]models.CanteenRating, error) {
	ratingQuery := h.db.Where("canteen_id = ? AND (status = ? OR status IS NULL OR status = '')", canteenID, models.ReviewEventStatusActive).Preload("User")
	switch filter {
	case "with_image":
		ratingQuery = ratingQuery.Where("images IS NOT NULL AND images <> '' AND images <> '[]'")
	case "high":
		ratingQuery = ratingQuery.Where("star >= ?", 4)
	case "low":
		ratingQuery = ratingQuery.Where("star <= ?", 2)
	}

	switch sortBy {
	case "latest":
		ratingQuery = ratingQuery.Order("created_at DESC")
	case "best":
		ratingQuery = ratingQuery.
			Order("(helpful_count - unhelpful_count * 2) DESC").
			Order("CASE WHEN comment IS NOT NULL AND TRIM(comment) <> '' THEN 1 ELSE 0 END DESC").
			Order("helpful_count DESC").
			Order("star DESC").
			Order("created_at DESC")
	default:
		ratingQuery = ratingQuery.
			Order("(helpful_count - unhelpful_count * 2) DESC").
			Order("CASE WHEN comment IS NOT NULL AND TRIM(comment) <> '' THEN 1 ELSE 0 END DESC").
			Order("helpful_count DESC").
			Order("star DESC").
			Order("created_at DESC")
	}

	var ratings []models.CanteenRating
	if err := ratingQuery.Find(&ratings).Error; err != nil {
		return nil, err
	}

	var ratingIDs []uint
	for i := range ratings {
		ratingIDs = append(ratingIDs, ratings[i].ID)
	}
	voteByRatingID := map[uint]string{}
	if viewerID != 0 && len(ratingIDs) > 0 {
		var votes []models.CanteenRatingVote
		if err := h.db.Where("rating_id IN ? AND user_id = ?", ratingIDs, viewerID).Find(&votes).Error; err == nil {
			for _, vote := range votes {
				voteByRatingID[vote.RatingID] = vote.VoteType
			}
		}
	}

	type ratingDishRecRow struct {
		RatingID uint   `gorm:"column:rating_id"`
		DishName string `gorm:"column:dish_name"`
	}
	recsByRatingID := map[uint][]string{}
	if len(ratingIDs) > 0 {
		var recRows []ratingDishRecRow
		if err := h.db.Table("canteen_rating_dish_recommendations").
			Select("rating_id, dish_name").
			Where("rating_id IN ?", ratingIDs).
			Order("id ASC").
			Find(&recRows).Error; err == nil {
			for _, row := range recRows {
				recsByRatingID[row.RatingID] = append(recsByRatingID[row.RatingID], row.DishName)
			}
		}
	}

	for i := range ratings {
		if ratings[i].User != nil {
			ratings[i].UserName = ratings[i].User.Nickname
			ratings[i].UserAvatar = ratings[i].User.Avatar
		}
		if vote, ok := voteByRatingID[ratings[i].ID]; ok {
			ratings[i].MyVote = &vote
		}
		if recs, ok := recsByRatingID[ratings[i].ID]; ok {
			ratings[i].RecommendedDishNames = recs
		}
	}
	return ratings, nil
}

// buildDisplayReviewsForViewer 生成某家店完整的混合评价流（V2 + 旧版），并补齐当前用户可见的
// 菜品名、实拍与投票。详情页首屏和分页接口共用，保证翻页与首屏顺序一致。
func (h *CanteenHandler) buildDisplayReviewsForViewer(canteen models.Canteen, sortBy, filter string, viewerID uint) ([]map[string]interface{}, []models.CanteenRating, error) {
	ratings, err := h.loadLegacyRatingsForDisplay(canteen.ID, sortBy, filter, viewerID)
	if err != nil {
		return nil, nil, err
	}
	allV2Reviews, err := h.loadCanteenReviews(canteen.ID, "latest", "all", false)
	if err != nil {
		return nil, nil, err
	}
	populateReviewDishNamesForViewer(h.db, allV2Reviews, viewerID)
	populateReviewDishPhotosForViewer(h.db, allV2Reviews, viewerID)
	if viewerID != 0 {
		populateReviewVotes(h.db, allV2Reviews, viewerID)
	}
	return buildCanteenDisplayReviews(canteen.Name, allV2Reviews, ratings, sortBy, filter), ratings, nil
}

// GetDisplayReviews 分页读取详情页的混合评价流；切换排序/筛选和“加载更多”只走这里，
// 不再重拉整页详情。
// GET /api/canteens/:id/display-reviews?sort=best|latest&filter=all|with_image|high|low&offset=0&limit=20
func (h *CanteenHandler) GetDisplayReviews(c *gin.Context) {
	cid, ok := parseCanteenID(c)
	if !ok {
		return
	}
	var canteen models.Canteen
	if err := h.db.Select("id", "name", "verified").First(&canteen, cid).Error; err != nil || !canteen.Verified {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}
	viewerID := uint(0)
	if rawUserID, exists := c.Get("user_id"); exists {
		if userID, ok := rawUserID.(uint); ok {
			viewerID = userID
		}
	}
	limit, limitErr := strconv.Atoi(c.DefaultQuery("limit", "20"))
	offset, offsetErr := strconv.Atoi(c.DefaultQuery("offset", "0"))
	if limitErr != nil || limit < 1 || limit > 50 || offsetErr != nil || offset < 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "分页参数无效"})
		return
	}
	sortBy, filter := normalizeDisplayReviewParams(c.DefaultQuery("sort", "best"), c.DefaultQuery("filter", "all"))
	items, _, err := h.buildDisplayReviewsForViewer(canteen, sortBy, filter, viewerID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取评价列表失败"})
		return
	}
	total := len(items)
	page := []map[string]interface{}{}
	if offset < total {
		end := total
		if offset+limit < total {
			end = offset + limit
		}
		page = items[offset:end]
	}
	c.JSON(http.StatusOK, gin.H{
		"items": page, "total": total, "sort": sortBy, "filter": filter,
		"has_more": offset+len(page) < total, "next_offset": offset + len(page),
	})
}

// buildCanteenDisplayReviews 生成详情页唯一使用的混合评价流。
// V2 优先于同一用户的 legacy 摘要；source 与 id 一起返回，避免两张表的自增 ID
// 碰撞导致投票或举报落到另一个用户的内容上。
func buildCanteenDisplayReviews(canteenName string, v2Reviews []models.CanteenReviewEvent, ratings []models.CanteenRating, sortBy, filter string) []map[string]interface{} {
	items := make([]map[string]interface{}, 0, len(v2Reviews)+len(ratings))
	v2Users := make(map[uint]struct{}, len(v2Reviews))
	for _, review := range v2Reviews {
		v2Users[review.UserID] = struct{}{}
		item := map[string]interface{}{
			"id": review.ID, "review_id": review.ID, "source": "v2", "review_source": "v2", "is_v2": true,
			"canteen_name": canteenName, "canteen_id": review.CanteenID, "user_id": review.UserID,
			"user_name": review.UserName, "user_avatar": review.UserAvatar, "credit_score": review.CreditScore,
			"credit_weight": review.CreditWeight, "history_count": review.HistoryCount,
			"star": review.OverallScore, "overall_score": review.OverallScore,
			"taste_score": review.TasteScore, "value_score": review.ValueScore, "queue_score": review.QueueScore,
			"hygiene_score": review.HygieneScore, "service_score": review.ServiceScore,
			"dimension_scores": map[string]int{"taste": review.TasteScore, "value": review.ValueScore, "queue": review.QueueScore, "hygiene": review.HygieneScore, "service": review.ServiceScore},
			"comment":          review.Comment, "images": review.Images, "tags": review.Tags,
			"recommended_dishes": review.RecommendedDishNames, "recommended_dish_details": review.RecommendedDishDetails,
			"dish_photos": review.DishPhotos, "helpful_count": review.HelpfulCount,
			"unhelpful_count": review.UnhelpfulCount, "my_vote": review.MyVote, "score_version": review.ScoreVersion,
			"created_at": review.CreatedAt, "updated_at": review.UpdatedAt,
		}
		if displayReviewMatchesFilter(item, filter) {
			items = append(items, item)
		}
	}
	for _, rating := range ratings {
		if _, ok := v2Users[rating.UserID]; ok {
			continue
		}
		item := map[string]interface{}{
			"id": rating.ID, "review_id": rating.ID, "source": "legacy", "review_source": "legacy", "is_v2": false,
			"canteen_name": canteenName, "canteen_id": rating.CanteenID, "user_id": rating.UserID,
			"user_name": rating.UserName, "user_avatar": rating.UserAvatar, "credit_score": rating.CreditScore,
			"credit_weight": rating.CreditWeight, "history_count": rating.HistoryCount,
			"star": rating.Star, "overall_score": rating.Star, "comment": rating.Comment,
			"images": rating.Images, "tags": rating.Tags, "recommended_dishes": rating.RecommendedDishNames,
			"helpful_count": rating.HelpfulCount, "unhelpful_count": rating.UnhelpfulCount,
			"my_vote": rating.MyVote, "score_version": 1, "created_at": rating.CreatedAt, "updated_at": rating.UpdatedAt,
		}
		if displayReviewMatchesFilter(item, filter) {
			items = append(items, item)
		}
	}
	sort.SliceStable(items, func(i, j int) bool {
		if sortBy == "latest" {
			return displayReviewTime(items[i]).After(displayReviewTime(items[j]))
		}
		wi := displayReviewHelpfulScore(items[i])
		wj := displayReviewHelpfulScore(items[j])
		if wi != wj {
			return wi > wj
		}
		ci := strings.TrimSpace(fmt.Sprint(items[i]["comment"])) != ""
		cj := strings.TrimSpace(fmt.Sprint(items[j]["comment"])) != ""
		if ci != cj {
			return ci
		}
		hi := intFromDisplay(items[i]["helpful_count"])
		hj := intFromDisplay(items[j]["helpful_count"])
		if hi != hj {
			return hi > hj
		}
		si := floatFromDisplay(items[i]["star"])
		sj := floatFromDisplay(items[j]["star"])
		if si != sj {
			return si > sj
		}
		return displayReviewTime(items[i]).After(displayReviewTime(items[j]))
	})
	return items
}

func displayReviewMatchesFilter(item map[string]interface{}, filter string) bool {
	switch filter {
	case "with_image":
		return hasReviewImages(fmt.Sprint(item["images"])) || hasDisplayDishPhotos(item["dish_photos"])
	case "high":
		return floatFromDisplay(item["star"]) >= 4-reviewScoreEpsilon
	case "low":
		return floatFromDisplay(item["star"]) <= 2+reviewScoreEpsilon
	default:
		return true
	}
}

func hasDisplayDishPhotos(raw interface{}) bool {
	switch photos := raw.(type) {
	case []map[string]interface{}:
		return len(photos) > 0
	case []interface{}:
		return len(photos) > 0
	case nil:
		return false
	default:
		return hasReviewImages(fmt.Sprint(raw))
	}
}

func displayReviewTime(item map[string]interface{}) time.Time {
	if value, ok := item["created_at"].(time.Time); ok {
		return value
	}
	return time.Time{}
}

func displayReviewHelpfulScore(item map[string]interface{}) int {
	return intFromDisplay(item["helpful_count"]) - 2*intFromDisplay(item["unhelpful_count"])
}

func intFromDisplay(value interface{}) int {
	switch number := value.(type) {
	case int:
		return number
	case int64:
		return int(number)
	case uint:
		return int(number)
	case float64:
		return int(number)
	default:
		return 0
	}
}

func floatFromDisplay(value interface{}) float64 {
	switch number := value.(type) {
	case float64:
		return number
	case float32:
		return float64(number)
	case int:
		return float64(number)
	case uint:
		return float64(number)
	default:
		return 0
	}
}

// VoteRating 给食堂评价点赞/点踩/取消投票
func (h *CanteenHandler) VoteRating(c *gin.Context) {
	userIDAny, _ := c.Get("user_id")
	userID := userIDAny.(uint)

	ratingID64, err := strconv.ParseUint(c.Param("ratingId"), 10, strconv.IntSize)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效评价ID"})
		return
	}
	ratingID := uint(ratingID64)

	var input struct {
		Vote string `json:"vote" binding:"required"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误"})
		return
	}
	if input.Vote != "up" && input.Vote != "down" && input.Vote != "none" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "投票类型不合法"})
		return
	}

	var updated models.CanteenRating
	myVote := input.Vote
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var rating models.CanteenRating
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&rating, ratingID).Error; err != nil {
			return err
		}
		if rating.UserID == userID {
			return errVoteOwnRating
		}

		var oldVote models.CanteenRatingVote
		oldVoteType := ""
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("rating_id = ? AND user_id = ?", ratingID, userID).
			First(&oldVote).Error
		if err == nil {
			oldVoteType = oldVote.VoteType
		} else if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}

		nextVote := input.Vote
		if oldVoteType == input.Vote {
			nextVote = "none"
		}

		helpfulDelta, unhelpfulDelta := ratingVoteDeltas(oldVoteType, nextVote)

		if nextVote == "none" {
			if oldVoteType != "" {
				if err := tx.Delete(&oldVote).Error; err != nil {
					return err
				}
			}
			myVote = ""
		} else if oldVoteType == "" {
			if err := tx.Create(&models.CanteenRatingVote{
				RatingID: ratingID,
				UserID:   userID,
				VoteType: nextVote,
			}).Error; err != nil {
				return err
			}
			myVote = nextVote
		} else {
			if err := tx.Model(&oldVote).Update("vote_type", nextVote).Error; err != nil {
				return err
			}
			myVote = nextVote
		}

		updates := map[string]interface{}{}
		if helpfulDelta != 0 {
			updates["helpful_count"] = nonNegativeCountExpr(tx, "helpful_count", helpfulDelta)
		}
		if unhelpfulDelta != 0 {
			updates["unhelpful_count"] = nonNegativeCountExpr(tx, "unhelpful_count", unhelpfulDelta)
		}
		if len(updates) > 0 {
			if err := tx.Model(&models.CanteenRating{}).Where("id = ?", ratingID).UpdateColumns(updates).Error; err != nil {
				return err
			}
		}

		return tx.First(&updated, ratingID).Error
	})

	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "评价不存在"})
		case errors.Is(err, errVoteOwnRating):
			c.JSON(http.StatusBadRequest, gin.H{"error": "不能给自己的评价投票"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "投票失败"})
		}
		return
	}

	var voteValue interface{}
	if myVote != "" {
		voteValue = myVote
	}
	c.JSON(http.StatusOK, gin.H{
		"message":         "操作成功",
		"rating_id":       updated.ID,
		"helpful_count":   updated.HelpfulCount,
		"unhelpful_count": updated.UnhelpfulCount,
		"my_vote":         voteValue,
	})
}

var errVoteOwnRating = errors.New("cannot vote on own rating")

func ratingVoteDeltas(oldVote, nextVote string) (int, int) {
	helpfulDelta := 0
	unhelpfulDelta := 0
	if oldVote == "up" {
		helpfulDelta--
	} else if oldVote == "down" {
		unhelpfulDelta--
	}
	if nextVote == "up" {
		helpfulDelta++
	} else if nextVote == "down" {
		unhelpfulDelta++
	}
	return helpfulDelta, unhelpfulDelta
}

func nonNegativeCountExpr(db *gorm.DB, column string, delta int) clause.Expr {
	if db.Dialector.Name() == "sqlite" {
		return gorm.Expr("CASE WHEN "+column+" + ? < 0 THEN 0 ELSE "+column+" + ? END", delta, delta)
	}
	return gorm.Expr("GREATEST("+column+" + ?, 0)", delta)
}

// Create 提交食堂；普通用户提交进入待审核状态，不会直接公开或获得经验。
func (h *CanteenHandler) Create(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var input struct {
		Name          string `json:"name" binding:"required"`
		Image         string `json:"image" binding:"required"`
		LocationArea  string `json:"location_area"`
		LocationFloor string `json:"location_floor"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	name := strings.TrimSpace(input.Name)
	if len([]rune(name)) < 2 || len([]rune(name)) > 100 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "食堂名称长度需在 2 到 100 个字符之间"})
		return
	}
	locationArea := strings.TrimSpace(input.LocationArea)
	if !models.IsValidCanteenLocationArea(locationArea) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "食堂位置区域只能是一食堂或二食堂"})
		return
	}
	locationFloor := strings.TrimSpace(input.LocationFloor)
	if !models.IsValidCanteenLocationFloor(locationFloor) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "食堂楼层只能是一楼或二楼"})
		return
	}
	image := strings.TrimSpace(input.Image)
	// 校验门面图片是真实的上传文件（/uploads 且已在 files 表登记），
	// 防止空值/假路径导致管理员审核时看不到提交图片。
	fileIDs, err := services.FileIDsByPublicPaths(h.db, image)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "图片校验失败"})
		return
	}
	if len(fileIDs) != 1 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请先上传商家门面图片"})
		return
	}
	if muted, err := services.IsCanteenMuted(h.db, userID.(uint)); err == nil && muted {
		c.JSON(http.StatusForbidden, gin.H{"code": "canteen_submission_muted", "error": "因已确认的食堂内容违规，暂时不能提交食堂评价或菜品投稿"})
		return
	}
	// 同位置同名的商家已存在时给出能看懂的原因：待审核的店在列表里搜不到，
	// 只说“已存在”会让后来的同学找不到这家店。
	var existing models.Canteen
	if err := h.db.Select("id", "name", "verified", "operating_status").
		Where("normalized_name = ? AND location_area = ? AND location_floor = ?", normalizeCanteenName(name), locationArea, locationFloor).
		First(&existing).Error; err == nil {
		existing.NormalizeOperatingStatus()
		switch {
		case !existing.Verified:
			c.JSON(http.StatusConflict, gin.H{"code": "canteen_pending_duplicate", "error": "这家店已有同学提交，正在审核中"})
		case existing.IsOffline:
			c.JSON(http.StatusConflict, gin.H{"code": "canteen_exists_offline", "error": "这家店已收录，目前已下架", "canteen_id": existing.ID})
		default:
			c.JSON(http.StatusConflict, gin.H{"code": "canteen_exists", "error": "这家店已收录，可以直接搜索「" + existing.Name + "」", "canteen_id": existing.ID})
		}
		return
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "添加失败"})
		return
	}
	canteen := models.Canteen{
		Name:            name,
		NormalizedName:  normalizeCanteenName(name),
		LocationArea:    locationArea,
		LocationFloor:   locationFloor,
		Image:           image,
		Verified:        false,
		OperatingStatus: models.CanteenOperatingActive,
		CreatedBy:       userID.(uint),
	}

	if err := h.db.Transaction(func(tx *gorm.DB) error {
		return tx.Create(&canteen).Error
	}); err != nil {
		if isUniqueConstraintError(err) {
			c.JSON(http.StatusConflict, gin.H{"error": "该食堂已存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "添加失败"})
		return
	}

	// 待审食堂仅在管理端待办/角标展示（/canteens/pending），不再写管理员个人通知。

	c.JSON(http.StatusCreated, gin.H{
		"message": "已提交审核",
		"canteen": canteen,
	})
}

func normalizeCanteenName(name string) string {
	return strings.ToLower(strings.Join(strings.Fields(strings.TrimSpace(name)), " "))
}

func isUniqueConstraintError(err error) bool {
	if err == nil {
		return false
	}
	lower := strings.ToLower(err.Error())
	return strings.Contains(lower, "unique constraint") || strings.Contains(lower, "duplicate key")
}

// Rate 评价食堂
func (h *CanteenHandler) Rate(c *gin.Context) {
	cid, err := strconv.ParseUint(c.Param("id"), 10, strconv.IntSize)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}

	var input struct {
		Star              int        `json:"star" binding:"required,min=1,max=5"`
		Comment           string     `json:"comment" binding:"max=500"`
		Images            string     `json:"images"`
		Tags              []string   `json:"tags"`
		RecommendedDishes []string   `json:"recommended_dishes"`
		BaseUpdatedAt     *time.Time `json:"base_updated_at"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	var canteen models.Canteen
	if err := h.db.First(&canteen, cid).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}
	if !canteen.Verified {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}
	canteen.NormalizeOperatingStatus()
	if canteen.IsOffline {
		c.JSON(http.StatusConflict, gin.H{"code": "canteen_offline", "error": "该店当前已下架，暂不能发布新的评价"})
		return
	}

	userIDValue, exists := c.Get("user_id")
	userID, validUserID := userIDValue.(uint)
	if !exists || !validUserID || userID == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{
			"error": "请先登录后评价",
			"code":  "authentication_required",
		})
		return
	}
	var user models.User
	if err := h.db.Select("id", "student_verified_at", "edu_bound").First(&user, userID).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{
			"error": "登录状态无效，请重新登录",
			"code":  "authentication_required",
		})
		return
	}
	verified, identityErr := models.HasVerifiedAcademicIdentity(h.db, userID)
	if identityErr != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取学生身份失败"})
		return
	}
	if !verified {
		c.JSON(http.StatusForbidden, gin.H{
			"error": "请先完成学生身份认证后评价",
			"code":  "edu_binding_required",
		})
		return
	}
	if muted, err := services.IsCanteenMuted(h.db, userID); err == nil && muted {
		c.JSON(http.StatusForbidden, gin.H{"code": "canteen_submission_muted", "error": "因已确认的食堂内容违规，暂时不能提交食堂评价或菜品投稿"})
		return
	}

	// 1. 体验标签白名单校验 & 去重 (最多 6 个)
	var cleanedTags []string
	seenTags := make(map[string]bool)
	for _, tag := range input.Tags {
		trimmed := strings.TrimSpace(tag)
		if trimmed == "" {
			continue
		}
		if _, ok := validCanteenTags[trimmed]; !ok {
			c.JSON(http.StatusBadRequest, gin.H{"error": "评价标签不合法"})
			return
		}
		if !seenTags[trimmed] {
			seenTags[trimmed] = true
			cleanedTags = append(cleanedTags, trimmed)
		}
	}
	if len(cleanedTags) > 6 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "最多选择6个体验标签"})
		return
	}
	tagsBytes, _ := json.Marshal(cleanedTags)
	tagsJSON := string(tagsBytes)
	if len(cleanedTags) == 0 {
		tagsJSON = "[]"
	}

	// 2. 图片列表解析与数量校验 (最多 3 张)
	var imagePaths []string
	if strings.TrimSpace(input.Images) != "" {
		if err := json.Unmarshal([]byte(input.Images), &imagePaths); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "图片列表格式错误"})
			return
		}
	}
	if len(imagePaths) > 3 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "最多只能上传3张评价图片"})
		return
	}
	for _, p := range imagePaths {
		if len([]rune(p)) > 500 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "图片路径长度过长"})
			return
		}
	}
	imagesBytes, _ := json.Marshal(imagePaths)
	normalizedImagesJSON := string(imagesBytes)
	if len(imagePaths) == 0 {
		normalizedImagesJSON = "[]"
	}

	// 3. 推荐菜品校验与标准化 (最多 3 道，允许学生自由输入，单菜名最大 30 字，同一评价内去重)
	type cleanedRec struct {
		DishName       string
		NormalizedName string
		DishID         *uint
	}
	var cleanedRecs []cleanedRec
	var cleanedDishNames []string
	seenDishNormalized := make(map[string]bool)

	for _, rawName := range input.RecommendedDishes {
		trimmed := strings.TrimSpace(rawName)
		if trimmed == "" {
			continue
		}
		if len([]rune(trimmed)) > 30 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "推荐菜名不能超过30个字符"})
			return
		}
		normalized := normalizeCanteenName(trimmed)
		if seenDishNormalized[normalized] {
			continue
		}
		seenDishNormalized[normalized] = true

		// 可选匹配已有活跃菜品实体以填充弱引用 DishID（绝不在此自动创建 CanteenDish）
		var matchedDish models.CanteenDish
		var dishIDPtr *uint
		if err := h.db.Select("id").
			Where("canteen_id = ? AND normalized_name = ? AND status = ?", cid, normalized, models.DishStatusActive).
			First(&matchedDish).Error; err == nil && matchedDish.ID > 0 {
			dishIDPtr = &matchedDish.ID
		}

		cleanedRecs = append(cleanedRecs, cleanedRec{
			DishName:       trimmed,
			NormalizedName: normalized,
			DishID:         dishIDPtr,
		})
		cleanedDishNames = append(cleanedDishNames, trimmed)
	}

	if len(cleanedRecs) > 3 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "最多只能推荐3道菜品"})
		return
	}

	now := time.Now()
	rating := models.CanteenRating{
		CanteenID: uint(cid),
		UserID:    userID,
		Star:      input.Star,
		Comment:   input.Comment,
		Images:    normalizedImagesJSON,
		Tags:      tagsJSON,
		UpdatedAt: now,
	}

	var savedRating models.CanteenRating
	var conflictErr *time.Time
	err = h.db.Transaction(func(tx *gorm.DB) error {
		// 与 V2 创建共用食堂行锁，避免 /rate 和 V2 并发写入产生混合摘要。
		var lockedCanteen models.Canteen
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&lockedCanteen, cid).Error; err != nil {
			return err
		}
		lockedCanteen.NormalizeOperatingStatus()
		if lockedCanteen.IsOffline {
			return errCanteenOffline
		}
		if tx.Migrator().HasTable(&models.CanteenReviewEvent{}) {
			var activeV2Count int64
			if err := tx.Model(&models.CanteenReviewEvent{}).
				Where("canteen_id = ? AND user_id = ? AND status = ? AND (score_version >= ? OR score_version = ?)", cid, userID, models.ReviewEventStatusActive, 2, 0).
				Count(&activeV2Count).Error; err != nil {
				if !isCanteenReviewSchemaMissing(err) {
					return err
				}
			}
			if activeV2Count > 0 {
				return errLegacyRatingSuperseded
			}
		}
		var existing models.CanteenRating
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("canteen_id = ? AND user_id = ?", cid, userID).
			First(&existing).Error; err == nil {
			if input.BaseUpdatedAt != nil && !input.BaseUpdatedAt.IsZero() {
				if existing.UpdatedAt.After(*input.BaseUpdatedAt) {
					remoteTime := existing.UpdatedAt
					conflictErr = &remoteTime
					return errors.New("rating_conflict")
				}
			}
		} else if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}

		if err := tx.Clauses(clause.OnConflict{
			Columns:   []clause.Column{{Name: "canteen_id"}, {Name: "user_id"}},
			DoUpdates: clause.AssignmentColumns([]string{"star", "comment", "images", "tags", "updated_at"}),
		}).Create(&rating).Error; err != nil {
			return err
		}

		if err := tx.Where("canteen_id = ? AND user_id = ?", cid, userID).First(&savedRating).Error; err != nil {
			return err
		}

		if err := tx.Where("rating_id = ?", savedRating.ID).Delete(&models.CanteenRatingDishRecommendation{}).Error; err != nil {
			return err
		}

		for _, recItem := range cleanedRecs {
			rec := models.CanteenRatingDishRecommendation{
				RatingID:       savedRating.ID,
				DishName:       recItem.DishName,
				NormalizedName: recItem.NormalizedName,
				DishID:         recItem.DishID,
			}
			if err := tx.Create(&rec).Error; err != nil {
				return err
			}
		}

		return services.ClaimPublicImagePathsForUser(tx, userID, imagePaths...)
	})
	if conflictErr != nil {
		c.JSON(http.StatusConflict, gin.H{
			"code":              "rating_conflict",
			"error":             "评价已在其他设备更新，请刷新后重试",
			"remote_updated_at": *conflictErr,
		})
		return
	}
	if err != nil {
		if errors.Is(err, errCanteenOffline) {
			c.JSON(http.StatusConflict, gin.H{"code": "canteen_offline", "error": "该店当前已下架，暂不能发布新的评价"})
			return
		}
		if errors.Is(err, errLegacyRatingSuperseded) {
			c.JSON(http.StatusConflict, gin.H{
				"code": "legacy_rating_superseded", "error": "该用户已使用新版评价，请通过新版评价修改",
			})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存评价失败"})
		return
	}

	savedRating.RecommendedDishNames = cleanedDishNames
	canteenDiscoveryCache.Invalidate() // 评价变更影响排行/首页
	c.JSON(http.StatusOK, gin.H{"message": "评价已保存", "rating": savedRating})
}

// deleteCanteenDependencies 只供永久删除使用。下架接口绝不调用它。
// 删除顺序遵循“关系 → 内容 → 实体”，并在删除图库行后通过文件引用服务回收权限。
func deleteCanteenDependencies(tx *gorm.DB, canteenID uint) error {
	var ratingIDs, eventIDs, dishIDs, photoIDs, photoFileIDs []uint
	if err := tx.Model(&models.CanteenRating{}).Where("canteen_id = ?", canteenID).Pluck("id", &ratingIDs).Error; err != nil {
		return err
	}
	if err := tx.Model(&models.CanteenReviewEvent{}).Where("canteen_id = ?", canteenID).Pluck("id", &eventIDs).Error; err != nil {
		return err
	}
	if err := tx.Model(&models.CanteenDish{}).Where("canteen_id = ?", canteenID).Pluck("id", &dishIDs).Error; err != nil {
		return err
	}
	if len(dishIDs) > 0 {
		if err := tx.Model(&models.CanteenDishPhoto{}).Where("dish_id IN ?", dishIDs).Pluck("id", &photoIDs).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.CanteenDishPhoto{}).Where("dish_id IN ?", dishIDs).Pluck("file_id", &photoFileIDs).Error; err != nil {
			return err
		}
	}
	if len(ratingIDs) > 0 {
		if err := tx.Where("rating_id IN ?", ratingIDs).Delete(&models.CanteenRatingVote{}).Error; err != nil {
			return err
		}
		if err := tx.Where("rating_id IN ?", ratingIDs).Delete(&models.CanteenRatingDishRecommendation{}).Error; err != nil {
			return err
		}
	}
	if len(eventIDs) > 0 {
		// 模型没有依赖数据库级 cascade，永久删除食堂时显式清理 V2 投票，
		// 避免 review_event_votes 残留并阻塞后续重建或造成孤儿数据。
		if err := tx.Where("review_event_id IN ?", eventIDs).Delete(&models.CanteenReviewEventVote{}).Error; err != nil {
			return err
		}
		if err := tx.Where("review_event_id IN ?", eventIDs).Delete(&models.CanteenReviewEventDish{}).Error; err != nil {
			return err
		}
	}
	if len(dishIDs) > 0 {
		if err := tx.Where("dish_id IN ?", dishIDs).Delete(&models.CanteenDishRatingSummary{}).Error; err != nil {
			return err
		}
		if err := tx.Where("dish_id IN ?", dishIDs).Delete(&models.CanteenDishAlias{}).Error; err != nil {
			return err
		}
		if err := tx.Where("dish_id IN ?", dishIDs).Delete(&models.CanteenDishPhoto{}).Error; err != nil {
			return err
		}
	}
	if len(eventIDs) > 0 || len(dishIDs) > 0 {
		query := tx.Where("1 = 0")
		if len(dishIDs) > 0 {
			query = query.Or("dish_id IN ?", dishIDs)
		}
		if len(eventIDs) > 0 {
			query = query.Or("canteen_review_event_id IN ?", eventIDs)
		}
		if err := query.Delete(&models.CanteenDishReviewEvent{}).Error; err != nil {
			return err
		}
	}
	if len(dishIDs) > 0 {
		if err := tx.Where("id IN ?", dishIDs).Delete(&models.CanteenDish{}).Error; err != nil {
			return err
		}
	}
	if len(eventIDs) > 0 {
		if err := tx.Where("id IN ?", eventIDs).Delete(&models.CanteenReviewEvent{}).Error; err != nil {
			return err
		}
	}
	if len(ratingIDs) > 0 {
		if err := tx.Where("id IN ?", ratingIDs).Delete(&models.CanteenRating{}).Error; err != nil {
			return err
		}
	}
	if len(photoIDs) > 0 && tx.Migrator().HasTable(&models.Report{}) {
		if err := tx.Where("target_type = ? AND target_id IN ?", "canteen_dish_photo", photoIDs).Delete(&models.Report{}).Error; err != nil {
			return err
		}
	}
	if len(eventIDs) > 0 && tx.Migrator().HasTable(&models.Report{}) {
		if err := tx.Where("target_type = ? AND target_id IN ?", "canteen_review", eventIDs).Delete(&models.Report{}).Error; err != nil {
			return err
		}
	}
	if (len(photoIDs) > 0 || len(eventIDs) > 0) && tx.Migrator().HasTable(&models.CanteenSanction{}) {
		if len(photoIDs) > 0 {
			if err := tx.Where("target_type = ? AND target_id IN ?", "canteen_dish_photo", photoIDs).Delete(&models.CanteenSanction{}).Error; err != nil {
				return err
			}
		}
		if len(eventIDs) > 0 {
			if err := tx.Where("target_type = ? AND target_id IN ?", "canteen_review", eventIDs).Delete(&models.CanteenSanction{}).Error; err != nil {
				return err
			}
		}
	}
	return services.ReconcileFilePublicAccess(tx, photoFileIDs...)
}

// DeleteCanteen 管理员永久删除食堂及其全部关联数据。下架请使用 OfflineCanteen。
func (h *CanteenHandler) DeleteCanteen(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, strconv.IntSize)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}

	var canteen models.Canteen
	if err := h.db.First(&canteen, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return
	}

	adminID, _ := c.Get("user_id")
	var admin models.User
	expRevoked := false
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Select("nickname").First(&admin, adminID).Error; err != nil {
			return err
		}
		// 事务内锁定重读，防止与审核通过/下架并发时漏算奖励经验。
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&canteen, id).Error; err != nil {
			return err
		}
		revoked, err := revokeCanteenSubmissionExp(tx, canteen.ID, canteen.CreatedBy, time.Now())
		if err != nil {
			return err
		}
		expRevoked = revoked
		if err := deleteCanteenDependencies(tx, uint(id)); err != nil {
			return err
		}
		if err := tx.Delete(&canteen).Error; err != nil {
			return err
		}
		return tx.Create(&models.AdminLog{
			AdminID: adminID.(uint), AdminName: admin.Nickname, Action: "删除食堂", Target: canteen.Name,
			Detail: fmt.Sprintf("删除食堂提交，创建者 %d，回收经验=%t", canteen.CreatedBy, expRevoked),
		}).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除食堂失败"})
		return
	}

	canteenDiscoveryCache.Invalidate() // 食堂删除影响排行/首页
	c.JSON(http.StatusOK, gin.H{"message": "已删除"})
}

// AdminListPending 返回等待审核的食堂提交，仅管理员可访问。
func (h *CanteenHandler) AdminListPending(c *gin.Context) {
	var canteens []models.Canteen
	if err := h.db.Where("verified = ? AND rejected_at IS NULL", false).Order("created_at ASC").Find(&canteens).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取待审核食堂失败"})
		return
	}
	if canteens == nil {
		canteens = []models.Canteen{}
	}
	attachCanteenCreatorNames(h.db, canteens)
	c.JSON(http.StatusOK, gin.H{"items": canteens})
}

// attachCanteenCreatorNames 为待审核列表补充提交人昵称，供管理端展示。
func attachCanteenCreatorNames(db *gorm.DB, canteens []models.Canteen) {
	if len(canteens) == 0 {
		return
	}
	ids := make(map[uint]struct{}, len(canteens))
	for _, canteen := range canteens {
		if canteen.CreatedBy != 0 {
			ids[canteen.CreatedBy] = struct{}{}
		}
	}
	if len(ids) == 0 {
		return
	}
	keys := make([]uint, 0, len(ids))
	for id := range ids {
		keys = append(keys, id)
	}
	var users []models.User
	if err := db.Select("id", "nickname").Where("id IN ?", keys).Find(&users).Error; err != nil {
		return
	}
	names := make(map[uint]string, len(users))
	for _, user := range users {
		names[user.ID] = user.Nickname
	}
	for i := range canteens {
		canteens[i].CreatorName = names[canteens[i].CreatedBy]
	}
}

// grantCanteenSubmissionExp 在事务内向提交者发放一次性奖励经验（幂等，仅首次发放）。
func grantCanteenSubmissionExp(tx *gorm.DB, canteenID, creatorID uint, now time.Time) (bool, error) {
	if creatorID == 0 {
		return false, nil
	}
	result := tx.Model(&models.Canteen{}).
		Where("id = ? AND exp_rewarded_at IS NULL", canteenID).
		UpdateColumn("exp_rewarded_at", now)
	if result.Error != nil {
		return false, result.Error
	}
	if result.RowsAffected == 0 {
		return false, nil
	}
	if err := tx.Model(&models.User{}).Where("id = ?", creatorID).
		UpdateColumn("exp", gorm.Expr("exp + ?", canteenSubmissionRewardExp)).Error; err != nil {
		return false, err
	}
	return true, nil
}

// revokeCanteenSubmissionExp 在事务内收回尚未收回的奖励经验（幂等），经验扣至下限 0。
func revokeCanteenSubmissionExp(tx *gorm.DB, canteenID, creatorID uint, now time.Time) (bool, error) {
	if creatorID == 0 {
		return false, nil
	}
	result := tx.Model(&models.Canteen{}).
		Where("id = ? AND exp_rewarded_at IS NOT NULL AND exp_revoked_at IS NULL", canteenID).
		UpdateColumn("exp_revoked_at", now)
	if result.Error != nil {
		return false, result.Error
	}
	if result.RowsAffected == 0 {
		return false, nil
	}
	if err := tx.Model(&models.User{}).Where("id = ?", creatorID).UpdateColumn(
		"exp",
		gorm.Expr("CASE WHEN exp >= ? THEN exp - ? ELSE 0 END", canteenSubmissionRewardExp, canteenSubmissionRewardExp),
	).Error; err != nil {
		return false, err
	}
	return true, nil
}

// restoreCanteenSubmissionExp 恢复营业时返还已收回的奖励经验（幂等）。
func restoreCanteenSubmissionExp(tx *gorm.DB, canteenID, creatorID uint) (bool, error) {
	if creatorID == 0 {
		return false, nil
	}
	result := tx.Model(&models.Canteen{}).
		Where("id = ? AND exp_rewarded_at IS NOT NULL AND exp_revoked_at IS NOT NULL", canteenID).
		UpdateColumn("exp_revoked_at", nil)
	if result.Error != nil {
		return false, result.Error
	}
	if result.RowsAffected == 0 {
		return false, nil
	}
	if err := tx.Model(&models.User{}).Where("id = ?", creatorID).
		UpdateColumn("exp", gorm.Expr("exp + ?", canteenSubmissionRewardExp)).Error; err != nil {
		return false, err
	}
	return true, nil
}

// ApproveCanteen 审核通过食堂，使其出现在公开列表并允许用户评价。
func (h *CanteenHandler) ApproveCanteen(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, strconv.IntSize)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	adminID := c.GetUint("user_id")
	var canteen models.Canteen
	expAwarded := false
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&canteen, id).Error; err != nil {
			return err
		}
		if canteen.Verified {
			return fmt.Errorf("canteen_already_verified")
		}
		if canteen.IsRejected() {
			return errCanteenSubmissionRejected
		}
		if err := tx.Model(&canteen).Update("verified", true).Error; err != nil {
			return err
		}
		var dishIDs []uint
		if err := tx.Model(&models.CanteenDish{}).Where("canteen_id = ?", canteen.ID).Pluck("id", &dishIDs).Error; err != nil {
			return err
		}
		if err := services.ReconcileDishPhotoPublicAccess(tx, dishIDs...); err != nil {
			return err
		}
		awarded, err := grantCanteenSubmissionExp(tx, canteen.ID, canteen.CreatedBy, time.Now())
		if err != nil {
			return err
		}
		expAwarded = awarded
		if err := services.ClaimPublicImagePaths(tx, canteen.Image); err != nil {
			return err
		}
		var admin models.User
		if err := tx.Select("nickname").First(&admin, adminID).Error; err != nil {
			return err
		}
		if err := tx.Create(&models.AdminLog{
			AdminID: adminID, AdminName: admin.Nickname, Action: "通过食堂审核", Target: canteen.Name,
			Detail: fmt.Sprintf("通过食堂提交（ID: %d），创建者 %d，奖励经验=%t", canteen.ID, canteen.CreatedBy, awarded),
		}).Error; err != nil {
			return err
		}
		CreateCanteenReviewResultNotification(tx, canteen.ID, canteen.CreatedBy, canteen.Name, true, "", canteenSubmissionRewardExp)
		return nil
	}); err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		case err.Error() == "canteen_already_verified":
			c.JSON(http.StatusConflict, gin.H{"error": "食堂已通过审核"})
		case errors.Is(err, errCanteenSubmissionRejected):
			c.JSON(http.StatusConflict, gin.H{"code": "canteen_submission_rejected", "error": "该提交已被驳回，不能再通过"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "审核食堂失败"})
		}
		return
	}
	canteen.Verified = true
	canteen.NormalizeOperatingStatus()
	canteenDiscoveryCache.Invalidate() // 新食堂公开影响排行/首页
	c.JSON(http.StatusOK, gin.H{"message": "审核已通过", "canteen": canteen, "exp_awarded": expAwarded})
}

var errCanteenSubmissionRejected = errors.New("canteen_submission_rejected")

// RejectCanteen 驳回待审核食堂；已公开食堂需使用常规删除接口处理。
// 驳回只做标记并保存原因，提交人可以在“我的贡献”里看到结果；
// 规范名改为占位值，腾出唯一索引让同学重新提交同名商家。
func (h *CanteenHandler) RejectCanteen(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, strconv.IntSize)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	var input struct {
		Reason string `json:"reason"`
	}
	if err := c.ShouldBindJSON(&input); err != nil && err != io.EOF {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误"})
		return
	}
	adminID := c.GetUint("user_id")
	var canteen models.Canteen
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&canteen, id).Error; err != nil {
			return err
		}
		if canteen.Verified {
			return fmt.Errorf("canteen_already_verified")
		}
		if canteen.IsRejected() {
			return errCanteenSubmissionRejected
		}
		if err := tx.Where("canteen_id = ?", canteen.ID).Delete(&models.CanteenRating{}).Error; err != nil {
			return err
		}
		now := time.Now()
		reason := strings.TrimSpace(input.Reason)
		if len([]rune(reason)) > 500 {
			reason = string([]rune(reason)[:500])
		}
		if err := tx.Model(&models.Canteen{}).Where("id = ?", canteen.ID).Updates(map[string]interface{}{
			"rejected_at":     now,
			"reject_reason":   reason,
			"normalized_name": models.CanteenRejectedNormalizedName(canteen.ID),
		}).Error; err != nil {
			return err
		}
		var admin models.User
		if err := tx.Select("nickname").First(&admin, adminID).Error; err != nil {
			return err
		}
		if err := tx.Create(&models.AdminLog{
			AdminID: adminID, AdminName: admin.Nickname, Action: "驳回食堂审核", Target: canteen.Name,
			Detail: fmt.Sprintf("驳回食堂提交（ID: %d），创建者 %d，原因：%s", canteen.ID, canteen.CreatedBy, strings.TrimSpace(input.Reason)),
		}).Error; err != nil {
			return err
		}
		CreateCanteenReviewResultNotification(tx, canteen.ID, canteen.CreatedBy, canteen.Name, false, input.Reason, 0)
		return nil
	}); err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		case err.Error() == "canteen_already_verified":
			c.JSON(http.StatusConflict, gin.H{"error": "已公开食堂不能按待审核驳回"})
		case errors.Is(err, errCanteenSubmissionRejected):
			c.JSON(http.StatusConflict, gin.H{"code": "canteen_submission_rejected", "error": "该提交已经驳回过了"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "驳回食堂失败"})
		}
		return
	}
	canteenDiscoveryCache.Invalidate() // 驳回食堂影响排行/首页
	c.JSON(http.StatusOK, gin.H{"message": "已驳回"})
}

// OfflineCanteen 下架已公开食堂：只改变营业状态，不删除任何业务数据。
// POST /api/canteens/:id/offline
func (h *CanteenHandler) OfflineCanteen(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, strconv.IntSize)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	var input struct {
		Reason string `json:"reason"`
	}
	if err := c.ShouldBindJSON(&input); err != nil && err != io.EOF {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误"})
		return
	}
	adminID := c.GetUint("user_id")
	var canteen models.Canteen
	alreadyOffline := false
	err = h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&canteen, id).Error; err != nil {
			return err
		}
		canteen.NormalizeOperatingStatus()
		if !canteen.Verified {
			return errors.New("canteen_not_verified")
		}
		if canteen.OperatingStatus == models.CanteenOperatingOffline {
			alreadyOffline = true
			return nil
		}
		now := time.Now()
		updates := map[string]interface{}{
			"operating_status": models.CanteenOperatingOffline,
			"offlined_at":      now, "offlined_by": adminID, "offline_reason": strings.TrimSpace(input.Reason),
		}
		if err := tx.Model(&canteen).Updates(updates).Error; err != nil {
			return err
		}
		canteen.OperatingStatus = models.CanteenOperatingOffline
		canteen.OfflinedAt, canteen.OfflinedBy = &now, &adminID
		canteen.OfflineReason = strings.TrimSpace(input.Reason)
		expRevoked, err := revokeCanteenSubmissionExp(tx, canteen.ID, canteen.CreatedBy, now)
		if err != nil {
			return err
		}
		var admin models.User
		if err := tx.Select("nickname").First(&admin, adminID).Error; err != nil {
			return err
		}
		return tx.Create(&models.AdminLog{AdminID: adminID, AdminName: admin.Nickname, Action: "下架食堂", Target: canteen.Name,
			Detail: fmt.Sprintf("食堂 %d 下架，回收经验=%t", canteen.ID, expRevoked)}).Error
	})
	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		case err.Error() == "canteen_not_verified":
			c.JSON(http.StatusConflict, gin.H{"error": "未审核食堂不能下架"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "下架食堂失败"})
		}
		return
	}
	canteen.NormalizeOperatingStatus()
	canteenDiscoveryCache.Invalidate()
	message := "食堂已下架"
	if alreadyOffline {
		message = "食堂已经处于下架状态"
	}
	c.JSON(http.StatusOK, gin.H{
		"message":        message,
		"canteen":        canteen,
		"offline_reason": canteen.OfflineReason,
	})
}

// OnlineCanteen 恢复已下架食堂：只恢复状态，不重置或重算历史评价。
// POST /api/canteens/:id/online
func (h *CanteenHandler) OnlineCanteen(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, strconv.IntSize)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	adminID := c.GetUint("user_id")
	var canteen models.Canteen
	alreadyOnline := false
	err = h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&canteen, id).Error; err != nil {
			return err
		}
		canteen.NormalizeOperatingStatus()
		if !canteen.Verified {
			return errors.New("canteen_not_verified")
		}
		if canteen.OperatingStatus == models.CanteenOperatingActive {
			alreadyOnline = true
			return nil
		}
		if err := tx.Model(&canteen).Updates(map[string]interface{}{
			"operating_status": models.CanteenOperatingActive,
			"offlined_at":      nil, "offlined_by": nil, "offline_reason": "",
		}).Error; err != nil {
			return err
		}
		canteen.OperatingStatus = models.CanteenOperatingActive
		canteen.OfflinedAt, canteen.OfflinedBy, canteen.OfflineReason = nil, nil, ""
		expRestored, err := restoreCanteenSubmissionExp(tx, canteen.ID, canteen.CreatedBy)
		if err != nil {
			return err
		}
		var admin models.User
		if err := tx.Select("nickname").First(&admin, adminID).Error; err != nil {
			return err
		}
		return tx.Create(&models.AdminLog{AdminID: adminID, AdminName: admin.Nickname, Action: "重新上架食堂", Target: canteen.Name,
			Detail: fmt.Sprintf("食堂 %d 重新上架，返还经验=%t", canteen.ID, expRestored)}).Error
	})
	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		case err.Error() == "canteen_not_verified":
			c.JSON(http.StatusConflict, gin.H{"error": "未审核食堂不能上架"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "重新上架食堂失败"})
		}
		return
	}
	canteen.NormalizeOperatingStatus()
	canteenDiscoveryCache.Invalidate()
	message := "食堂已重新上架"
	if alreadyOnline {
		message = "食堂已经处于营业状态"
	}
	c.JSON(http.StatusOK, gin.H{
		"message":        message,
		"canteen":        canteen,
		"offline_reason": canteen.OfflineReason,
	})
}

// UpdateImage 管理员修改食堂图片
func (h *CanteenHandler) UpdateImage(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, strconv.IntSize)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}

	var input struct {
		Image string `json:"image" binding:"required,url|filepath"` // 可以用 custom validation，这里简单要求 required
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "图片地址不能为空"})
		return
	}

	image := strings.TrimSpace(input.Image)
	if image == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "图片地址不能为空"})
		return
	}

	if !strings.HasPrefix(image, "/uploads/") {
		c.JSON(http.StatusBadRequest, gin.H{"error": "图片地址必须来自站内上传"})
		return
	}

	input.Image = image

	// 开启事务
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var canteen models.Canteen
		if err := tx.First(&canteen, id).Error; err != nil {
			return fmt.Errorf("食堂不存在")
		}

		oldImage := canteen.Image
		canteen.Image = input.Image

		if err := tx.Save(&canteen).Error; err != nil {
			return fmt.Errorf("更新食堂图片失败")
		}
		if canteen.Verified {
			if err := services.ClaimPublicImagePaths(tx, canteen.Image); err != nil {
				return fmt.Errorf("公开食堂图片失败")
			}
		}

		// 记录管理员操作
		adminID, _ := c.Get("user_id")
		var admin models.User
		if err := tx.Select("nickname").First(&admin, adminID).Error; err != nil {
			return fmt.Errorf("获取管理员信息失败")
		}

		detail := fmt.Sprintf("管理员修改食堂图片： %s（ID: %d），旧图片：%s，新图片：%s", canteen.Name, canteen.ID, oldImage, input.Image)

		if err := tx.Create(&models.AdminLog{
			AdminID:   adminID.(uint),
			AdminName: admin.Nickname,
			Action:    "修改食堂图片",
			Target:    canteen.Name,
			Detail:    detail,
		}).Error; err != nil {
			return fmt.Errorf("记录管理员操作失败")
		}

		// 返回给外部使用
		c.Set("updated_canteen", canteen)
		return nil
	})

	if err != nil {
		if err.Error() == "食堂不存在" {
			c.JSON(http.StatusNotFound, gin.H{"error": err.Error()})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		}
		return
	}

	updatedCanteen, _ := c.Get("updated_canteen")
	canteenDiscoveryCache.Invalidate() // 封面变更影响排行/首页缩略图
	c.JSON(http.StatusOK, gin.H{
		"message": "食堂图片已更新",
		"canteen": updatedCanteen,
	})
}

var errCanteenNameConflict = errors.New("canteen_name_conflict")

// AdminUpdateCanteen 管理员修改商家名称与位置；只改传入的字段，评价、菜品等历史数据不受影响。
// PATCH /api/canteens/:id  body: {"name"?, "location_area"?, "location_floor"?}
func (h *CanteenHandler) AdminUpdateCanteen(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, strconv.IntSize)
	if err != nil || id == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	var input struct {
		Name          *string `json:"name"`
		LocationArea  *string `json:"location_area"`
		LocationFloor *string `json:"location_floor"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误"})
		return
	}
	if input.Name == nil && input.LocationArea == nil && input.LocationFloor == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请提供要修改的名称或位置"})
		return
	}
	if input.Name != nil {
		name := strings.TrimSpace(*input.Name)
		if n := len([]rune(name)); n < 2 || n > 100 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "食堂名称长度需在 2 到 100 个字符之间"})
			return
		}
		input.Name = &name
	}
	if input.LocationArea != nil {
		area := strings.TrimSpace(*input.LocationArea)
		if !models.IsValidCanteenLocationArea(area) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "食堂位置区域不合法"})
			return
		}
		input.LocationArea = &area
	}
	if input.LocationFloor != nil {
		floor := strings.TrimSpace(*input.LocationFloor)
		if !models.IsValidCanteenLocationFloor(floor) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "食堂楼层不合法"})
			return
		}
		input.LocationFloor = &floor
	}
	adminID := c.GetUint("user_id")
	var canteen models.Canteen
	err = h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&canteen, id).Error; err != nil {
			return err
		}
		before := fmt.Sprintf("%s（%s %s）", canteen.Name, canteen.LocationArea, canteen.LocationFloor)
		if input.Name != nil {
			canteen.Name = *input.Name
			canteen.NormalizedName = normalizeCanteenName(*input.Name)
		}
		if input.LocationArea != nil {
			canteen.LocationArea = *input.LocationArea
		}
		if input.LocationFloor != nil {
			canteen.LocationFloor = *input.LocationFloor
		}
		// 名称+位置唯一由数据库索引兜底；这里先查一次给出可读的冲突提示。
		var conflict int64
		if err := tx.Model(&models.Canteen{}).
			Where("normalized_name = ? AND location_area = ? AND location_floor = ? AND id <> ?",
				canteen.NormalizedName, canteen.LocationArea, canteen.LocationFloor, canteen.ID).
			Count(&conflict).Error; err != nil {
			return err
		}
		if conflict > 0 {
			return errCanteenNameConflict
		}
		if err := tx.Model(&models.Canteen{}).Where("id = ?", canteen.ID).Updates(map[string]interface{}{
			"name": canteen.Name, "normalized_name": canteen.NormalizedName,
			"location_area": canteen.LocationArea, "location_floor": canteen.LocationFloor,
		}).Error; err != nil {
			return err
		}
		after := fmt.Sprintf("%s（%s %s）", canteen.Name, canteen.LocationArea, canteen.LocationFloor)
		return tx.Create(&models.AdminLog{
			AdminID: adminID, AdminName: adminNickname(tx, adminID), Action: "修改食堂信息", Target: canteen.Name,
			Detail: fmt.Sprintf("食堂 %d：%s → %s", canteen.ID, before, after),
		}).Error
	})
	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		case errors.Is(err, errCanteenNameConflict), isUniqueConstraintError(err):
			c.JSON(http.StatusConflict, gin.H{"code": "canteen_name_conflict", "error": "同一位置已有同名商家"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "修改食堂信息失败"})
		}
		return
	}
	canteen.NormalizeOperatingStatus()
	canteenDiscoveryCache.Invalidate()
	c.JSON(http.StatusOK, gin.H{"message": "食堂信息已更新", "canteen": canteen})
}
