package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
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
}

func NewCanteenHandler(db *gorm.DB) *CanteenHandler {
	return &CanteenHandler{db: db}
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

// canteenStatsRow 食堂聚合统计行（GetList / GetRankings / GetHome 共用）。
// RankingScore 与 Rank 由调用方基于全局均值（globalMean）在 Go 内计算。
//
// 注意：排序与评分计算全部放在 Go 层，而不是 SQL。
// 历史教训：把「全校平均分 globalMean」写成 SQL 嵌套子查询，在外层 GROUP BY 下作为
// 算术操作数求值时，SQLite 会返回 NULL/0 导致公式退化为 (n/(n+m))*R，顺序失真。
// Go 层计算对 SQLite/PostgreSQL 行为一致、可单元测试、可解释。
type canteenStatsRow struct {
	models.Canteen
	RatingCount    int     `json:"rating_count"`
	AverageStar    float64 `json:"average_star"`
	DishCount      int     `json:"dish_count"`
	DishPhotoCount int     `json:"dish_photo_count"`
	RankingScore   float64 `json:"ranking_score"`
}

// canteenRankingEntry 一条可排名的食堂项（含计算出的 Bayesian score 与 rank）。
type canteenRankingEntry struct {
	canteenStatsRow
	RankingScore float64
	Rank         int
}

// queryCanteenStats 拉取全部 verified 食堂的聚合统计。
// 终端尾部保留一个稳定次序（created_at DESC, id DESC），供排序同分时作最后 tie-break。
func (h *CanteenHandler) queryCanteenStats() ([]canteenStatsRow, error) {
	var rows []canteenStatsRow
	// 独立聚合子查询（rating_stats / dish_stats），避免 JOIN 膨胀污染 COUNT。
	// 不再内嵌 globalMean 子查询（SQLite 算术语境陷阱，见 canteenStatsRow 注释）。
	err := h.db.Table("canteens").
		Select(`canteens.*,
			COALESCE(rs.rating_count, 0) as rating_count,
			COALESCE(rs.average_star, 0) as average_star,
			COALESCE(ds.dish_count, 0) as dish_count,
			COALESCE(ds.dish_photo_count, 0) as dish_photo_count`).
		Joins(`LEFT JOIN (
			SELECT canteen_id, COUNT(*) as rating_count, AVG(CAST(star AS FLOAT)) as average_star
			FROM canteen_ratings GROUP BY canteen_id
		) rs ON rs.canteen_id = canteens.id`).
		Joins(`LEFT JOIN (
			SELECT d.canteen_id,
				COUNT(DISTINCT CASE WHEN p.id IS NOT NULL THEN d.id END) as dish_count,
				COUNT(p.id) as dish_photo_count
			FROM canteen_dishes d
			LEFT JOIN canteen_dish_photos p ON p.dish_id = d.id AND p.status = 'approved'
			WHERE d.status = 'active'
			GROUP BY d.canteen_id
		) ds ON ds.canteen_id = canteens.id`).
		Where("canteens.verified = ?", true).
		Group("canteens.id, rs.rating_count, rs.average_star, ds.dish_count, ds.dish_photo_count").
		Order("canteens.created_at DESC, canteens.id DESC").
		Scan(&rows).Error
	return rows, err
}

// globalMeanStars 计算全体「有评价」食堂的平均星级（Bayesian 公式里的 C）。
// 与原始 SQL 语义一致：从按食堂分组的平均分再取一次均值；无评价食堂不参与。
func globalMeanStars(rows []canteenStatsRow) float64 {
	var sum float64
	var n int
	for _, r := range rows {
		if r.RatingCount > 0 {
			sum += r.AverageStar
			n++
		}
	}
	if n == 0 {
		return 0
	}
	return sum / float64(n)
}

// sortRanking 按 mode 策略排序并赋 rank，tie-break 稳定（都退到 rating_count → average → created_at → id）。
func sortRanking(entries []canteenRankingEntry, mode string) {
	less := func(a, b canteenRankingEntry) bool {
		var ka, kb float64
		var na, nb int
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
			return ka > kb
		}
		if na != nb {
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

// GetList 获取食堂列表（Bayesian 综合排序，无评价食堂置后）。兼容旧客户端字段。
func (h *CanteenHandler) GetList(c *gin.Context) {
	rows, err := h.queryCanteenStats()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取食堂列表失败"})
		return
	}
	mean := globalMeanStars(rows)
	entries := make([]canteenRankingEntry, 0, len(rows))
	for _, r := range rows {
		score := services.BayesianRatingScore(r.AverageStar, float64(r.RatingCount), mean, services.BayesianPriorWeight)
		entries = append(entries, canteenRankingEntry{canteenStatsRow: r, RankingScore: score})
	}
	sortRanking(entries, "composite")

	// 返回结构保持旧客户端兼容（顶层数组，新增 ranking_score 字段旧端忽略）。
	out := make([]canteenStatsRow, 0, len(entries))
	for _, e := range entries {
		row := e.canteenStatsRow
		row.RankingScore = services.BayesianScoreTo100(e.RankingScore)
		out = append(out, row)
	}
	c.JSON(http.StatusOK, out)
}

// GetDetail 食堂详情（含评价列表）
func (h *CanteenHandler) GetDetail(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
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

	ratingQuery := h.db.Where("canteen_id = ?", id).Preload("User")
	switch reviewFilter {
	case "with_image":
		ratingQuery = ratingQuery.Where("images IS NOT NULL AND images <> '' AND images <> '[]'")
	case "high":
		ratingQuery = ratingQuery.Where("star >= ?", 4)
	case "low":
		ratingQuery = ratingQuery.Where("star <= ?", 2)
	case "all":
	default:
		reviewFilter = "all"
	}

	switch reviewSort {
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
		reviewSort = "best"
		ratingQuery = ratingQuery.
			Order("(helpful_count - unhelpful_count * 2) DESC").
			Order("CASE WHEN comment IS NOT NULL AND TRIM(comment) <> '' THEN 1 ELSE 0 END DESC").
			Order("helpful_count DESC").
			Order("star DESC").
			Order("created_at DESC")
	}

	var ratings []models.CanteenRating
	if err := ratingQuery.Find(&ratings).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取评价列表失败"})
		return
	}

	var ratingIDs []uint
	for i := range ratings {
		ratingIDs = append(ratingIDs, ratings[i].ID)
	}
	voteByRatingID := map[uint]string{}
	if userID, exists := c.Get("user_id"); exists && len(ratingIDs) > 0 {
		var votes []models.CanteenRatingVote
		if err := h.db.Where("rating_id IN ? AND user_id = ?", ratingIDs, userID).Find(&votes).Error; err == nil {
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

	var count int64
	var avg float64
	h.db.Model(&models.CanteenRating{}).Where("canteen_id = ?", id).Count(&count)
	if count > 0 {
		h.db.Model(&models.CanteenRating{}).Where("canteen_id = ?", id).Select("AVG(CAST(star AS FLOAT))").Scan(&avg)
	}

	var myRating *models.CanteenRating
	if userID, exists := c.Get("user_id"); exists {
		var rating models.CanteenRating
		if err := h.db.Where("canteen_id = ? AND user_id = ?", id, userID).First(&rating).Error; err == nil {
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
	}

	c.JSON(http.StatusOK, gin.H{
		"canteen":      canteen,
		"ratings":      ratings,
		"rating_count": count,
		"average_star": avg,
		"my_rating":    myRating,
	})
}

// VoteRating 给食堂评价点赞/点踩/取消投票
func (h *CanteenHandler) VoteRating(c *gin.Context) {
	userIDAny, _ := c.Get("user_id")
	userID := userIDAny.(uint)

	ratingID64, err := strconv.ParseUint(c.Param("ratingId"), 10, 64)
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
		Name  string `json:"name" binding:"required"`
		Image string `json:"image" binding:"required"`
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
	canteen := models.Canteen{
		Name:           name,
		NormalizedName: normalizeCanteenName(name),
		Image:          input.Image,
		Verified:       false,
		CreatedBy:      userID.(uint),
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
	cid, err := strconv.ParseUint(c.Param("id"), 10, 64)
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
	if !user.IsStudentVerified() {
		c.JSON(http.StatusForbidden, gin.H{
			"error": "请先绑定教务账号后评价",
			"code":  "edu_binding_required",
		})
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
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存评价失败"})
		return
	}

	savedRating.RecommendedDishNames = cleanedDishNames
	canteenDiscoveryCache.Invalidate() // 评价变更影响排行/首页
	c.JSON(http.StatusOK, gin.H{"message": "评价已保存", "rating": savedRating})
}

// DeleteCanteen 管理员删除食堂（驳回并扣除10经验）
func (h *CanteenHandler) DeleteCanteen(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
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
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Select("nickname").First(&admin, adminID).Error; err != nil {
			return err
		}
		var ratingIDs []uint
		if err := tx.Model(&models.CanteenRating{}).Where("canteen_id = ?", id).Pluck("id", &ratingIDs).Error; err != nil {
			return err
		}
		if len(ratingIDs) > 0 {
			if err := tx.Where("rating_id IN ?", ratingIDs).Delete(&models.CanteenRatingDishRecommendation{}).Error; err != nil {
				return err
			}
		}
		if err := tx.Where("canteen_id = ?", id).Delete(&models.CanteenRating{}).Error; err != nil {
			return err
		}
		if err := tx.Delete(&canteen).Error; err != nil {
			return err
		}
		return tx.Create(&models.AdminLog{
			AdminID: adminID.(uint), AdminName: admin.Nickname, Action: "删除食堂", Target: canteen.Name,
			Detail: fmt.Sprintf("删除食堂提交，创建者 %d", canteen.CreatedBy),
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
	if err := h.db.Where("verified = ?", false).Order("created_at ASC").Find(&canteens).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取待审核食堂失败"})
		return
	}
	if canteens == nil {
		canteens = []models.Canteen{}
	}
	c.JSON(http.StatusOK, gin.H{"items": canteens})
}

// ApproveCanteen 审核通过食堂，使其出现在公开列表并允许用户评价。
func (h *CanteenHandler) ApproveCanteen(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
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
		if err := tx.Model(&canteen).Update("verified", true).Error; err != nil {
			return err
		}
		if err := services.ClaimPublicImagePaths(tx, canteen.Image); err != nil {
			return err
		}
		var admin models.User
		if err := tx.Select("nickname").First(&admin, adminID).Error; err != nil {
			return err
		}
		return tx.Create(&models.AdminLog{
			AdminID: adminID, AdminName: admin.Nickname, Action: "通过食堂审核", Target: canteen.Name,
			Detail: fmt.Sprintf("通过食堂提交（ID: %d），创建者 %d", canteen.ID, canteen.CreatedBy),
		}).Error
	}); err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		case err.Error() == "canteen_already_verified":
			c.JSON(http.StatusConflict, gin.H{"error": "食堂已通过审核"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "审核食堂失败"})
		}
		return
	}
	canteen.Verified = true
	canteenDiscoveryCache.Invalidate() // 新食堂公开影响排行/首页
	c.JSON(http.StatusOK, gin.H{"message": "审核已通过", "canteen": canteen})
}

// RejectCanteen 驳回待审核食堂；已公开食堂需使用常规删除接口处理。
func (h *CanteenHandler) RejectCanteen(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
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
		if err := tx.Where("canteen_id = ?", canteen.ID).Delete(&models.CanteenRating{}).Error; err != nil {
			return err
		}
		if err := tx.Delete(&canteen).Error; err != nil {
			return err
		}
		var admin models.User
		if err := tx.Select("nickname").First(&admin, adminID).Error; err != nil {
			return err
		}
		return tx.Create(&models.AdminLog{
			AdminID: adminID, AdminName: admin.Nickname, Action: "驳回食堂审核", Target: canteen.Name,
			Detail: fmt.Sprintf("驳回食堂提交（ID: %d），创建者 %d", canteen.ID, canteen.CreatedBy),
		}).Error
	}); err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		case err.Error() == "canteen_already_verified":
			c.JSON(http.StatusConflict, gin.H{"error": "已公开食堂不能按待审核驳回"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "驳回食堂失败"})
		}
		return
	}
	canteenDiscoveryCache.Invalidate() // 驳回食堂影响排行/首页
	c.JSON(http.StatusOK, gin.H{"message": "已驳回"})
}

// UpdateImage 管理员修改食堂图片
func (h *CanteenHandler) UpdateImage(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
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
