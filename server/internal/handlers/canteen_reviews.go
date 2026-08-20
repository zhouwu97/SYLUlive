package handlers

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"shenliyuan/internal/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const reviewCreateCooldown = 6 * time.Hour

type reviewDishInput struct {
	DishID       uint   `json:"dish_id"`
	TasteScore   int    `json:"taste_score"`
	ValueScore   int    `json:"value_score"`
	PortionScore int    `json:"portion_score"`
	Comment      string `json:"comment"`
}

type canteenReviewInput struct {
	TasteScore   int      `json:"taste_score"`
	ValueScore   int      `json:"value_score"`
	QueueScore   int      `json:"queue_score"`
	HygieneScore int      `json:"hygiene_score"`
	ServiceScore int      `json:"service_score"`
	Comment      string   `json:"comment"`
	Images       []string `json:"images"`
	Tags         []string `json:"tags"`
	// DishIDs 表示“推荐/吃过”的菜品关系；DishReviews 只表示用户主动填写的菜品评分。
	// 两者拆开后，推荐菜不再因为没有填写三项分数而被静默丢弃。
	DishIDs       []uint            `json:"dish_ids"`
	DishNames     []string          `json:"dish_names"`
	DishReviews   []reviewDishInput `json:"dish_reviews"`
	BaseUpdatedAt *time.Time        `json:"base_updated_at"`
}

// CreateReview 创建一次新的到店评价。旧 /rate 接口继续保留给旧客户端。
// POST /api/canteens/:id/reviews
func (h *CanteenHandler) CreateReview(c *gin.Context) {
	cid, ok := parseCanteenID(c)
	if !ok {
		return
	}
	var input canteenReviewInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误"})
		return
	}
	if !services.ValidateVisitScores(services.VisitScores{
		Taste: input.TasteScore, Value: input.ValueScore, Queue: input.QueueScore,
		Hygiene: input.HygieneScore, Service: input.ServiceScore,
	}) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "五个评分维度均需为1到5分"})
		return
	}
	if len([]rune(input.Comment)) > 500 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "评价文字不能超过500字"})
		return
	}
	userID, ok := requireVerifiedStudent(c, h.db, "评价")
	if !ok {
		return
	}
	if muted, err := services.IsCanteenMuted(h.db, userID); err == nil && muted {
		c.JSON(http.StatusForbidden, gin.H{"code": "canteen_submission_muted", "error": "因已确认的食堂内容违规，暂时不能提交食堂评价或菜品投稿"})
		return
	}
	if !h.ensureVerifiedCanteen(c, cid) {
		return
	}
	if !h.ensureCanteenOperatingActive(c, cid) {
		return
	}
	cleanedImages, err := cleanReviewImages(input.Images)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	cleanedTags, err := cleanReviewTags(input.Tags)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if len(input.DishReviews) > 3 || len(input.DishIDs) > 3 || len(input.DishNames) > 3 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "最多选择3道菜品"})
		return
	}

	var saved models.CanteenReviewEvent
	var lastReview *models.CanteenReviewEvent
	err = h.db.Transaction(func(tx *gorm.DB) error {
		// 锁定食堂行作为同一用户/食堂创建评价的轻量串行闸门，兼容 SQLite/PostgreSQL。
		var canteen models.Canteen
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&canteen, cid).Error; err != nil {
			return err
		}
		canteen.NormalizeOperatingStatus()
		if canteen.IsOffline {
			return errCanteenOffline
		}
		if err := tx.Where("canteen_id = ? AND user_id = ? AND status = ? AND (score_version >= ? OR score_version = ?)", cid, userID, models.ReviewEventStatusActive, 2, 0).
			Order("created_at DESC, id DESC").First(&lastReview).Error; err == nil && time.Since(lastReview.CreatedAt) < reviewCreateCooldown {
			return errReviewTooFrequent
		} else if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		if err := ensureLegacyReviewEvent(tx, cid, userID); err != nil {
			return err
		}

		now := time.Now()
		saved = models.CanteenReviewEvent{
			CanteenID: cid, UserID: userID,
			TasteScore: input.TasteScore, ValueScore: input.ValueScore, QueueScore: input.QueueScore,
			HygieneScore: input.HygieneScore, ServiceScore: input.ServiceScore,
			OverallScore: services.ComputeVisitOverall(services.VisitScores{
				Taste: input.TasteScore, Value: input.ValueScore, Queue: input.QueueScore,
				Hygiene: input.HygieneScore, Service: input.ServiceScore,
			}),
			Comment: input.Comment, Images: encodeStringList(cleanedImages), Tags: encodeStringList(cleanedTags),
			Status: models.ReviewEventStatusActive, ScoreVersion: 2, CreatedAt: now, UpdatedAt: now,
		}
		if err := tx.Create(&saved).Error; err != nil {
			return err
		}
		selectedDishIDs, err := h.resolveReviewDishIDs(tx, cid, input.DishIDs, input.DishNames, input.DishReviews)
		if err != nil {
			return err
		}
		if err := h.syncDishReviews(tx, cid, userID, saved.ID, selectedDishIDs, input.DishReviews); err != nil {
			return err
		}
		if err := recomputeCanteenUserSummary(tx, cid, userID); err != nil {
			return err
		}
		return services.ClaimPublicImagePathsForUser(tx, userID, cleanedImages...)
	})
	if err != nil {
		if errors.Is(err, errReviewTooFrequent) {
			seconds := int(reviewCreateCooldown.Seconds())
			if lastReview != nil {
				remaining := int(math.Ceil(reviewCreateCooldown.Seconds() - time.Since(lastReview.CreatedAt).Seconds()))
				if remaining > 0 {
					seconds = remaining
				}
			}
			c.JSON(http.StatusTooManyRequests, gin.H{
				"code": "review_too_frequent", "error": "你刚刚评价过这家店，可以修改最近一次评价",
				"last_review_id": lastReviewID(lastReview), "retry_after_seconds": seconds,
			})
			return
		}
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
			return
		}
		if errors.Is(err, errCanteenOffline) {
			c.JSON(http.StatusConflict, gin.H{"code": "canteen_offline", "error": "该店当前已下架，暂不能发布新的评价"})
			return
		}
		if errors.Is(err, errReviewDishInvalid) {
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_review_dish", "error": err.Error()})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存评价失败"})
		return
	}
	populateReviewPublicFields(h.db, &saved)
	canteenDiscoveryCache.Invalidate()
	c.JSON(http.StatusCreated, gin.H{"message": "评价已保存", "review": saved})
}

// UpdateReview 修改自己最近的一次到店评价。
// PATCH /api/canteens/reviews/:reviewId
func (h *CanteenHandler) UpdateReview(c *gin.Context) {
	reviewID, err := strconv.ParseUint(c.Param("reviewId"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效评价ID"})
		return
	}
	var input canteenReviewInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误"})
		return
	}
	if !services.ValidateVisitScores(services.VisitScores{Taste: input.TasteScore, Value: input.ValueScore, Queue: input.QueueScore, Hygiene: input.HygieneScore, Service: input.ServiceScore}) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "五个评分维度均需为1到5分"})
		return
	}
	userID, ok := requireVerifiedStudent(c, h.db, "修改评价")
	if !ok {
		return
	}
	if muted, err := services.IsCanteenMuted(h.db, userID); err == nil && muted {
		c.JSON(http.StatusForbidden, gin.H{"code": "canteen_submission_muted", "error": "因已确认的食堂内容违规，暂时不能提交食堂评价或菜品投稿"})
		return
	}
	cleanedImages, err := cleanReviewImages(input.Images)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if len(input.DishReviews) > 3 || len(input.DishIDs) > 3 || len(input.DishNames) > 3 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "最多选择3道菜品"})
		return
	}
	cleanedTags, err := cleanReviewTags(input.Tags)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	var review models.CanteenReviewEvent
	err = h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&review, reviewID).Error; err != nil {
			return err
		}
		if review.UserID != userID {
			return errReviewForbidden
		}
		if review.Status != models.ReviewEventStatusActive {
			return errReviewNotActive
		}
		var latest models.CanteenReviewEvent
		if err := tx.Where("canteen_id = ? AND user_id = ? AND status = ?", review.CanteenID, review.UserID, models.ReviewEventStatusActive).
			Order("created_at DESC, id DESC").First(&latest).Error; err != nil {
			return err
		}
		if latest.ID != review.ID {
			return errReviewNotLatest
		}
		if input.BaseUpdatedAt != nil && review.UpdatedAt.After(*input.BaseUpdatedAt) {
			return errReviewConflict
		}
		oldImages := decodeStringList(review.Images)
		oldImageFileIDs, err := services.FileIDsByPublicPaths(tx, oldImages...)
		if err != nil {
			return err
		}
		review.TasteScore, review.ValueScore, review.QueueScore = input.TasteScore, input.ValueScore, input.QueueScore
		review.HygieneScore, review.ServiceScore = input.HygieneScore, input.ServiceScore
		review.OverallScore = services.ComputeVisitOverall(services.VisitScores{Taste: input.TasteScore, Value: input.ValueScore, Queue: input.QueueScore, Hygiene: input.HygieneScore, Service: input.ServiceScore})
		review.Comment, review.Images, review.Tags = input.Comment, encodeStringList(cleanedImages), encodeStringList(cleanedTags)
		review.UpdatedAt = time.Now()
		if err := tx.Save(&review).Error; err != nil {
			return err
		}
		selectedDishIDs, err := h.resolveReviewDishIDs(tx, review.CanteenID, input.DishIDs, input.DishNames, input.DishReviews)
		if err != nil {
			return err
		}
		if err := h.syncDishReviews(tx, review.CanteenID, review.UserID, review.ID, selectedDishIDs, input.DishReviews); err != nil {
			return err
		}
		if err := recomputeCanteenUserSummary(tx, review.CanteenID, review.UserID); err != nil {
			return err
		}
		if err := services.ClaimPublicImagePathsForUser(tx, userID, cleanedImages...); err != nil {
			return err
		}
		return services.ReconcileFilePublicAccess(tx, oldImageFileIDs...)
	})
	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "评价不存在"})
		case errors.Is(err, errReviewForbidden):
			c.JSON(http.StatusForbidden, gin.H{"error": "只能修改自己的评价"})
		case errors.Is(err, errReviewNotActive):
			c.JSON(http.StatusConflict, gin.H{"error": "该评价当前不可修改"})
		case errors.Is(err, errReviewNotLatest):
			c.JSON(http.StatusConflict, gin.H{"code": "review_not_latest", "error": "只能修改最近一次评价，请刷新后重试"})
		case errors.Is(err, errReviewConflict):
			c.JSON(http.StatusConflict, gin.H{"code": "review_conflict", "error": "评价已在其他设备更新，请刷新后重试", "remote_updated_at": review.UpdatedAt})
		case errors.Is(err, errReviewDishInvalid):
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_review_dish", "error": err.Error()})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "保存评价失败"})
		}
		return
	}
	populateReviewPublicFields(h.db, &review)
	canteenDiscoveryCache.Invalidate()
	c.JSON(http.StatusOK, gin.H{"message": "评价已保存", "review": review})
}

// VoteReview 给 V2 到店评价投有用/无用票，协议与旧评价保持一致。
// PUT /api/canteens/reviews/:reviewId/vote
func (h *CanteenHandler) VoteReview(c *gin.Context) {
	userID, ok := c.Get("user_id")
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录后操作"})
		return
	}
	uid, valid := userID.(uint)
	if !valid || uid == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "登录状态无效"})
		return
	}
	reviewID, err := strconv.ParseUint(c.Param("reviewId"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效评价ID"})
		return
	}
	var input struct {
		Vote string `json:"vote" binding:"required"`
	}
	if err := c.ShouldBindJSON(&input); err != nil || (input.Vote != "up" && input.Vote != "down" && input.Vote != "none") {
		c.JSON(http.StatusBadRequest, gin.H{"error": "投票类型不合法"})
		return
	}

	var updated models.CanteenReviewEvent
	myVote := input.Vote
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var review models.CanteenReviewEvent
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&review, uint(reviewID)).Error; err != nil {
			return err
		}
		if review.Status != models.ReviewEventStatusActive {
			return errReviewNotActive
		}
		if review.UserID == uid {
			return errVoteOwnRating
		}
		var oldVote models.CanteenReviewEventVote
		oldType := ""
		voteErr := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("review_event_id = ? AND user_id = ?", review.ID, uid).First(&oldVote).Error
		if voteErr == nil {
			oldType = oldVote.VoteType
		} else if !errors.Is(voteErr, gorm.ErrRecordNotFound) {
			return voteErr
		}
		next := input.Vote
		if oldType == input.Vote {
			next = "none"
		}
		helpfulDelta, unhelpfulDelta := ratingVoteDeltas(oldType, next)
		switch {
		case next == "none" && oldType != "":
			if err := tx.Delete(&oldVote).Error; err != nil {
				return err
			}
			myVote = ""
		case next != "none" && oldType == "":
			if err := tx.Create(&models.CanteenReviewEventVote{ReviewEventID: review.ID, UserID: uid, VoteType: next}).Error; err != nil {
				return err
			}
			myVote = next
		case next != "none":
			if err := tx.Model(&oldVote).Update("vote_type", next).Error; err != nil {
				return err
			}
			myVote = next
		}
		updates := map[string]interface{}{}
		if helpfulDelta != 0 {
			updates["helpful_count"] = nonNegativeCountExpr(tx, "helpful_count", helpfulDelta)
		}
		if unhelpfulDelta != 0 {
			updates["unhelpful_count"] = nonNegativeCountExpr(tx, "unhelpful_count", unhelpfulDelta)
		}
		if len(updates) > 0 {
			if err := tx.Model(&models.CanteenReviewEvent{}).Where("id = ?", review.ID).Updates(updates).Error; err != nil {
				return err
			}
		}
		return tx.First(&updated, review.ID).Error
	})
	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "评价不存在"})
		case errors.Is(err, errReviewNotActive):
			c.JSON(http.StatusConflict, gin.H{"error": "评价当前不可投票"})
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
	c.JSON(http.StatusOK, gin.H{"message": "操作成功", "review_id": updated.ID, "helpful_count": updated.HelpfulCount, "unhelpful_count": updated.UnhelpfulCount, "my_vote": voteValue})
}

// GetReviews 默认每位用户只展示最近一次，history=1 时返回该店所有有效事件。
// GET /api/canteens/:id/reviews
func (h *CanteenHandler) GetReviews(c *gin.Context) {
	cid, ok := parseCanteenID(c)
	if !ok {
		return
	}
	if !h.ensureVerifiedCanteen(c, cid) {
		return
	}
	sortBy := strings.ToLower(strings.TrimSpace(c.DefaultQuery("sort", "latest")))
	if sortBy != "latest" && sortBy != "best" {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_review_sort", "error": "评价排序不合法"})
		return
	}
	filter := strings.ToLower(strings.TrimSpace(c.DefaultQuery("filter", "all")))
	if !isReviewFilter(filter) {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_review_filter", "error": "评价筛选不合法"})
		return
	}
	history := c.Query("history") == "1"
	events, err := h.loadCanteenReviews(cid, sortBy, filter, history)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取评价失败"})
		return
	}
	if rawCursor := strings.TrimSpace(c.Query("cursor")); rawCursor != "" {
		cursor, err := decodeReviewCursor(rawCursor)
		if err != nil || cursor.Sort != sortBy || cursor.Filter != filter || cursor.History != history {
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_review_cursor", "error": "评价分页游标无效或已改变筛选条件"})
			return
		}
		events = eventsAfterCursor(events, cursor)
	}
	limit := 50
	if parsed, err := strconv.Atoi(c.DefaultQuery("limit", "50")); err == nil && parsed > 0 {
		if parsed > 100 {
			parsed = 100
		}
		limit = parsed
	}
	hasMore := len(events) > limit
	if hasMore {
		events = events[:limit]
	}
	for i := range events {
		populateReviewPublicFields(h.db, &events[i])
	}
	populateReviewDishNames(h.db, events)
	if uid, exists := c.Get("user_id"); exists {
		if userID, ok := uid.(uint); ok {
			populateReviewVotes(h.db, events, userID)
		}
	}
	response := gin.H{"items": events, "count": len(events)}
	if hasMore && len(events) > 0 {
		response["next_cursor"] = encodeReviewCursor(reviewCursor{
			Sort: sortBy, Filter: filter, History: history,
			Overall:   events[len(events)-1].OverallScore,
			CreatedAt: events[len(events)-1].CreatedAt, ID: events[len(events)-1].ID,
		})
	}
	c.JSON(http.StatusOK, response)
}

type reviewCursor struct {
	Sort      string    `json:"sort"`
	Filter    string    `json:"filter"`
	History   bool      `json:"history"`
	Overall   float64   `json:"overall"`
	CreatedAt time.Time `json:"created_at"`
	ID        uint      `json:"id"`
}

func isReviewFilter(filter string) bool {
	switch filter {
	case "all", "with_image", "high", "low":
		return true
	default:
		return false
	}
}

func hasReviewImages(images string) bool {
	trimmed := strings.TrimSpace(images)
	return trimmed != "" && trimmed != "[]" && trimmed != "null"
}

func reviewMatchesFilter(review models.CanteenReviewEvent, filter string) bool {
	switch filter {
	case "with_image":
		return hasReviewImages(review.Images)
	case "high":
		return review.OverallScore >= 4
	case "low":
		return review.OverallScore <= 2
	default:
		return true
	}
}

// loadCanteenReviews 固定先按时间找每人最新事件，再筛选，再按请求排序。
// 这保证 best/with_image 等组合不会因为先排序后去重而丢掉用户的最新评价。
func (h *CanteenHandler) loadCanteenReviews(canteenID uint, sortBy, filter string, history bool) ([]models.CanteenReviewEvent, error) {
	var all []models.CanteenReviewEvent
	if !h.db.Migrator().HasTable(&models.CanteenReviewEvent{}) {
		return []models.CanteenReviewEvent{}, nil
	}
	if err := h.db.Where("canteen_id = ? AND status = ?", canteenID, models.ReviewEventStatusActive).
		Preload("User").Order("created_at DESC, id DESC").Find(&all).Error; err != nil {
		// 旧测试库/旧部署可能尚未创建 V2 表；此时继续由 ratings 字段提供兼容数据。
		if isCanteenReviewSchemaMissing(err) {
			return []models.CanteenReviewEvent{}, nil
		}
		return nil, err
	}
	if !history {
		seen := make(map[uint]bool, len(all))
		latest := make([]models.CanteenReviewEvent, 0, len(all))
		for _, event := range all {
			if seen[event.UserID] {
				continue
			}
			seen[event.UserID] = true
			latest = append(latest, event)
		}
		all = latest
	}
	filtered := all[:0]
	for _, event := range all {
		if reviewMatchesFilter(event, filter) {
			filtered = append(filtered, event)
		}
	}
	all = filtered
	sort.SliceStable(all, func(i, j int) bool {
		if sortBy == "best" && all[i].OverallScore != all[j].OverallScore {
			return all[i].OverallScore > all[j].OverallScore
		}
		if !all[i].CreatedAt.Equal(all[j].CreatedAt) {
			return all[i].CreatedAt.After(all[j].CreatedAt)
		}
		return all[i].ID > all[j].ID
	})
	for i := range all {
		populateReviewPublicFields(h.db, &all[i])
	}
	populateReviewDishNames(h.db, all)
	return all, nil
}

// loadMyLatestReviewPayload 返回编辑器所需的事件级数据。
//
// my_rating 是旧摘要模型，只适合旧客户端展示，不能作为 V2 编辑请求的权威来源；
// 这里把事件、选中的菜以及该事件下的菜品评分一次性返回，避免编辑保存时把未回填的
// 菜品关系误判为用户主动删除。
func (h *CanteenHandler) loadMyLatestReviewPayload(canteenID, userID uint) (map[string]interface{}, error) {
	if !h.db.Migrator().HasTable(&models.CanteenReviewEvent{}) {
		return nil, nil
	}
	var event models.CanteenReviewEvent
	if err := h.db.Where("canteen_id = ? AND user_id = ? AND status = ? AND score_version >= ?", canteenID, userID, models.ReviewEventStatusActive, 2).
		Order("created_at DESC, id DESC").First(&event).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) || isCanteenReviewSchemaMissing(err) {
			return nil, nil
		}
		return nil, err
	}

	type selectedDishRow struct {
		DishID uint   `gorm:"column:dish_id"`
		Name   string `gorm:"column:name"`
	}
	selectedDishes := make([]selectedDishRow, 0, 3)
	if h.db.Migrator().HasTable(&models.CanteenReviewEventDish{}) {
		if err := h.db.Table("canteen_review_event_dishes AS relation").
			Select("relation.dish_id, dish.name").
			Joins("JOIN canteen_dishes AS dish ON dish.id = relation.dish_id").
			Where("relation.review_event_id = ? AND dish.status = ?", event.ID, models.DishStatusActive).
			Order("relation.id ASC").Find(&selectedDishes).Error; err != nil && !isCanteenReviewSchemaMissing(err) {
			return nil, err
		}
	}

	dishNames := make(map[uint]string, len(selectedDishes))
	recommendedDishes := make([]map[string]interface{}, 0, len(selectedDishes))
	for _, dish := range selectedDishes {
		dishNames[dish.DishID] = dish.Name
		recommendedDishes = append(recommendedDishes, map[string]interface{}{
			"dish_id": dish.DishID,
			"name":    dish.Name,
		})
	}

	type dishReviewPayload struct {
		DishID       uint   `json:"dish_id"`
		DishName     string `json:"dish_name,omitempty"`
		TasteScore   int    `json:"taste_score"`
		ValueScore   int    `json:"value_score"`
		PortionScore int    `json:"portion_score"`
		Comment      string `json:"comment"`
	}
	dishReviews := make([]dishReviewPayload, 0, len(selectedDishes))
	if h.db.Migrator().HasTable(&models.CanteenDishReviewEvent{}) {
		var events []models.CanteenDishReviewEvent
		if err := h.db.Where("canteen_review_event_id = ? AND status = ?", event.ID, models.ReviewEventStatusActive).
			Order("id ASC").Find(&events).Error; err != nil && !isCanteenReviewSchemaMissing(err) {
			return nil, err
		} else if err == nil {
			for _, item := range events {
				dishReviews = append(dishReviews, dishReviewPayload{
					DishID: item.DishID, DishName: dishNames[item.DishID],
					TasteScore: item.TasteScore, ValueScore: item.ValueScore,
					PortionScore: item.PortionScore, Comment: item.Comment,
				})
			}
		}
	}

	return map[string]interface{}{
		"review_event_id":    event.ID,
		"id":                 event.ID,
		"canteen_id":         event.CanteenID,
		"user_id":            event.UserID,
		"star":               event.OverallScore,
		"overall_score":      event.OverallScore,
		"taste_score":        event.TasteScore,
		"value_score":        event.ValueScore,
		"queue_score":        event.QueueScore,
		"hygiene_score":      event.HygieneScore,
		"service_score":      event.ServiceScore,
		"comment":            event.Comment,
		"images":             event.Images,
		"tags":               event.Tags,
		"score_version":      event.ScoreVersion,
		"created_at":         event.CreatedAt,
		"updated_at":         event.UpdatedAt,
		"recommended_dishes": recommendedDishes,
		"dish_reviews":       dishReviews,
	}, nil
}

func populateReviewDishNames(db *gorm.DB, reviews []models.CanteenReviewEvent) {
	ids := make([]uint, 0, len(reviews))
	for _, review := range reviews {
		if review.ID != 0 {
			ids = append(ids, review.ID)
		}
	}
	if len(ids) == 0 {
		return
	}
	type dishNameRow struct {
		ReviewEventID uint   `gorm:"column:review_event_id"`
		Name          string `gorm:"column:name"`
	}
	var rows []dishNameRow
	if err := db.Table("canteen_review_event_dishes AS r").
		Select("r.review_event_id, d.name").
		Joins("JOIN canteen_dishes d ON d.id = r.dish_id").
		Where("r.review_event_id IN ? AND d.status = ?", ids, models.DishStatusActive).
		Order("r.id ASC").Find(&rows).Error; err != nil {
		return
	}
	byReview := make(map[uint][]string, len(rows))
	for _, row := range rows {
		byReview[row.ReviewEventID] = append(byReview[row.ReviewEventID], row.Name)
	}
	for i := range reviews {
		reviews[i].RecommendedDishNames = byReview[reviews[i].ID]
	}
}

func populateReviewVotes(db *gorm.DB, reviews []models.CanteenReviewEvent, userID uint) {
	if userID == 0 || len(reviews) == 0 {
		return
	}
	ids := make([]uint, 0, len(reviews))
	for _, review := range reviews {
		ids = append(ids, review.ID)
	}
	var votes []models.CanteenReviewEventVote
	if err := db.Where("review_event_id IN ? AND user_id = ?", ids, userID).Find(&votes).Error; err != nil {
		return
	}
	byReview := make(map[uint]string, len(votes))
	for _, vote := range votes {
		byReview[vote.ReviewEventID] = vote.VoteType
	}
	for i := range reviews {
		if vote, ok := byReview[reviews[i].ID]; ok {
			reviews[i].MyVote = &vote
		}
	}
}

func encodeReviewCursor(cursor reviewCursor) string {
	payload, _ := json.Marshal(cursor)
	return base64.RawURLEncoding.EncodeToString(payload)
}

func decodeReviewCursor(raw string) (reviewCursor, error) {
	var cursor reviewCursor
	payload, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return cursor, err
	}
	err = json.Unmarshal(payload, &cursor)
	if err == nil && (cursor.Sort == "" || cursor.Filter == "" || cursor.CreatedAt.IsZero() || cursor.ID == 0) {
		err = errors.New("incomplete review cursor")
	}
	return cursor, err
}

func eventsAfterCursor(events []models.CanteenReviewEvent, cursor reviewCursor) []models.CanteenReviewEvent {
	filtered := events[:0]
	for _, event := range events {
		if cursor.Sort == "best" {
			if event.OverallScore > cursor.Overall {
				continue
			}
			if event.OverallScore == cursor.Overall {
				if event.CreatedAt.After(cursor.CreatedAt) || (event.CreatedAt.Equal(cursor.CreatedAt) && event.ID >= cursor.ID) {
					continue
				}
			}
		} else if event.CreatedAt.After(cursor.CreatedAt) || (event.CreatedAt.Equal(cursor.CreatedAt) && event.ID >= cursor.ID) {
			continue
		}
		filtered = append(filtered, event)
	}
	return filtered
}

// GetReviewHistory 获取某个用户在某店的历史到店评价。
// GET /api/canteens/:id/reviews/history/:userId
func (h *CanteenHandler) GetReviewHistory(c *gin.Context) {
	cid, ok := parseCanteenID(c)
	if !ok {
		return
	}
	if !h.ensureVerifiedCanteen(c, cid) {
		return
	}
	userID, err := strconv.ParseUint(c.Param("userId"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效用户ID"})
		return
	}
	var events []models.CanteenReviewEvent
	if err := h.db.Where("canteen_id = ? AND user_id = ? AND status = ?", cid, userID, models.ReviewEventStatusActive).
		Preload("User").Order("created_at DESC, id DESC").Find(&events).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取评价历史失败"})
		return
	}
	for i := range events {
		populateReviewPublicFields(h.db, &events[i])
	}
	populateReviewDishNames(h.db, events)
	c.JSON(http.StatusOK, gin.H{"items": events, "count": len(events)})
}

// GetDishSuggestions 返回精确/别名/模糊候选。模糊候选永远只提示，不自动合并。
// GET /api/canteens/:id/dish-suggestions?q=...
func (h *CanteenHandler) GetDishSuggestions(c *gin.Context) {
	cid, ok := parseCanteenID(c)
	if !ok {
		return
	}
	if !h.ensureVerifiedCanteen(c, cid) {
		return
	}
	query := utils.NormalizeDishName(c.Query("q"))
	var dishes []models.CanteenDish
	if err := h.db.Where("canteen_id = ? AND status = ?", cid, models.DishStatusActive).Find(&dishes).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取菜品候选失败"})
		return
	}
	type suggestion struct {
		DishID      uint   `json:"dish_id"`
		Name        string `json:"name"`
		MatchType   string `json:"match_type"`
		RatingCount int    `json:"rating_count"`
	}
	var aliases []models.CanteenDishAlias
	_ = h.db.Where("canteen_id = ?", cid).Find(&aliases).Error
	aliasByDish := map[uint][]string{}
	for _, alias := range aliases {
		aliasByDish[alias.DishID] = append(aliasByDish[alias.DishID], alias.NormalizedAlias)
	}
	results := make([]suggestion, 0, len(dishes))
	for _, dish := range dishes {
		matchType := ""
		normalized := utils.NormalizeDishName(dish.Name)
		if query == "" {
			matchType = "popular"
		} else if query == normalized {
			matchType = "exact"
		} else {
			for _, alias := range aliasByDish[dish.ID] {
				if query == alias {
					matchType = "alias"
					break
				}
			}
			if matchType == "" && (strings.Contains(normalized, query) || strings.Contains(query, normalized) || runeEditDistance(query, normalized) <= 1) {
				matchType = "possible"
			}
		}
		if matchType == "" {
			continue
		}
		var count int64
		h.db.Model(&models.CanteenDishRatingSummary{}).Where("dish_id = ?", dish.ID).Count(&count)
		results = append(results, suggestion{DishID: dish.ID, Name: dish.Name, MatchType: matchType, RatingCount: int(count)})
	}
	sort.SliceStable(results, func(i, j int) bool {
		priority := map[string]int{"exact": 0, "alias": 1, "possible": 2, "popular": 3}
		if priority[results[i].MatchType] != priority[results[j].MatchType] {
			return priority[results[i].MatchType] < priority[results[j].MatchType]
		}
		return results[i].RatingCount > results[j].RatingCount
	})
	if len(results) > 8 {
		results = results[:8]
	}
	c.JSON(http.StatusOK, gin.H{"items": results})
}

// CreateDishReview 创建独立菜品评价。
// POST /api/canteens/dishes/:dishId/reviews
func (h *CanteenHandler) CreateDishReview(c *gin.Context) {
	dishID, err := strconv.ParseUint(c.Param("dishId"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效菜品ID"})
		return
	}
	var input struct {
		TasteScore           int    `json:"taste_score"`
		ValueScore           int    `json:"value_score"`
		PortionScore         int    `json:"portion_score"`
		Comment              string `json:"comment"`
		CanteenReviewEventID *uint  `json:"canteen_review_event_id"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误"})
		return
	}
	if !services.ValidateDishScores(services.DishScores{Taste: input.TasteScore, Value: input.ValueScore, Portion: input.PortionScore}) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "菜品评分均需为1到5分"})
		return
	}
	userID, ok := requireVerifiedStudent(c, h.db, "评价菜品")
	if !ok {
		return
	}
	if muted, err := services.IsCanteenMuted(h.db, userID); err == nil && muted {
		c.JSON(http.StatusForbidden, gin.H{"code": "canteen_submission_muted", "error": "因已确认的食堂内容违规，暂时不能提交食堂评价或菜品投稿"})
		return
	}
	var dish models.CanteenDish
	if err := h.db.Where("id = ? AND status = ?", dishID, models.DishStatusActive).First(&dish).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "菜品不存在"})
		return
	}
	if !h.ensureCanteenOperatingActive(c, dish.CanteenID) {
		return
	}
	event := models.CanteenDishReviewEvent{
		DishID: uint(dishID), UserID: userID, TasteScore: input.TasteScore, ValueScore: input.ValueScore,
		PortionScore: input.PortionScore,
		OverallScore: services.ComputeDishOverall(services.DishScores{Taste: input.TasteScore, Value: input.ValueScore, Portion: input.PortionScore}),
		Comment:      input.Comment, Status: models.ReviewEventStatusActive, ScoreVersion: 1,
		CanteenReviewEventID: input.CanteenReviewEventID,
	}
	err = h.db.Transaction(func(tx *gorm.DB) error {
		// 与 CreateReview 保持相同的加锁顺序：先锁食堂，再锁菜品，避免并发死锁。
		if _, err := lockActiveCanteen(tx, dish.CanteenID); err != nil {
			return err
		}
		var lockedDish models.CanteenDish
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND status = ?", dishID, models.DishStatusActive).First(&lockedDish).Error; err != nil {
			return err
		}
		if input.CanteenReviewEventID != nil {
			var parent models.CanteenReviewEvent
			if err := tx.First(&parent, *input.CanteenReviewEventID).Error; err != nil {
				if errors.Is(err, gorm.ErrRecordNotFound) {
					return errDishReviewEventInvalid
				}
				return err
			}
			if parent.UserID != userID {
				return errDishReviewEventForbidden
			}
			if parent.CanteenID != lockedDish.CanteenID || parent.Status != models.ReviewEventStatusActive {
				return errDishReviewEventInvalid
			}
		}
		if err := tx.Create(&event).Error; err != nil {
			return err
		}
		if input.CanteenReviewEventID != nil {
			if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&models.CanteenReviewEventDish{
				ReviewEventID: *input.CanteenReviewEventID, DishID: uint(dishID), Relation: models.DishReviewRelationAte,
			}).Error; err != nil {
				return err
			}
		}
		return recomputeDishUserSummary(tx, event.DishID, event.UserID)
	})
	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "菜品不存在"})
		case errors.Is(err, errDishReviewEventForbidden):
			c.JSON(http.StatusForbidden, gin.H{"code": "review_event_forbidden", "error": "只能关联自己的到店评价"})
		case errors.Is(err, errDishReviewEventInvalid):
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_canteen_review_event", "error": "到店评价不存在、已隐藏或不属于该食堂"})
		case errors.Is(err, errCanteenOffline):
			c.JSON(http.StatusConflict, gin.H{"code": "canteen_offline", "error": "该店当前已下架，暂不能发布新的评价"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "保存菜品评价失败"})
		}
		return
	}
	populateDishReviewPublicFields(h.db, &event)
	canteenDiscoveryCache.Invalidate()
	c.JSON(http.StatusCreated, gin.H{"message": "菜品评价已保存", "review": event})
}

// GetDishReviews 获取菜品评价，默认按用户去重展示最近一条。
func (h *CanteenHandler) GetDishReviews(c *gin.Context) {
	dishID, err := strconv.ParseUint(c.Param("dishId"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效菜品ID"})
		return
	}
	var events []models.CanteenDishReviewEvent
	if err := h.db.Where("dish_id = ? AND status = ?", dishID, models.ReviewEventStatusActive).
		Preload("User").Order("created_at DESC, id DESC").Find(&events).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取菜品评价失败"})
		return
	}
	if c.Query("history") != "1" {
		seen := map[uint]bool{}
		latest := events[:0]
		for _, event := range events {
			if seen[event.UserID] {
				continue
			}
			seen[event.UserID] = true
			latest = append(latest, event)
		}
		events = latest
	}
	for i := range events {
		populateDishReviewPublicFields(h.db, &events[i])
	}
	c.JSON(http.StatusOK, gin.H{"items": events, "count": len(events)})
}

var (
	errReviewTooFrequent        = errors.New("review_too_frequent")
	errReviewForbidden          = errors.New("review_forbidden")
	errReviewNotActive          = errors.New("review_not_active")
	errReviewNotLatest          = errors.New("review_not_latest")
	errReviewConflict           = errors.New("review_conflict")
	errReviewDishInvalid        = errors.New("review_dish_invalid")
	errDishReviewEventInvalid   = errors.New("dish_review_event_invalid")
	errDishReviewEventForbidden = errors.New("dish_review_event_forbidden")
	errLegacyRatingSuperseded   = errors.New("legacy_rating_superseded")
)

func parseCanteenID(c *gin.Context) (uint, bool) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || id == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return 0, false
	}
	return uint(id), true
}

func requireVerifiedStudent(c *gin.Context, db *gorm.DB, action string) (uint, bool) {
	value, exists := c.Get("user_id")
	userID, valid := value.(uint)
	if !exists || !valid || userID == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录后" + action, "code": "authentication_required"})
		return 0, false
	}
	var user models.User
	if err := db.Select("id", "student_verified_at").First(&user, userID).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "登录状态无效，请重新登录", "code": "authentication_required"})
		return 0, false
	}
	if !user.IsStudentVerified() {
		c.JSON(http.StatusForbidden, gin.H{"error": "请先绑定教务账号后" + action, "code": "edu_binding_required"})
		return 0, false
	}
	return userID, true
}

func (h *CanteenHandler) ensureVerifiedCanteen(c *gin.Context, id uint) bool {
	var canteen models.Canteen
	if err := h.db.Select("id", "verified").First(&canteen, id).Error; err != nil || !canteen.Verified {
		c.JSON(http.StatusNotFound, gin.H{"error": "食堂不存在"})
		return false
	}
	return true
}

func cleanReviewImages(images []string) ([]string, error) {
	if len(images) > 3 {
		return nil, errors.New("最多只能上传3张评价图片")
	}
	cleaned := make([]string, 0, len(images))
	for _, image := range images {
		image = strings.TrimSpace(image)
		if image == "" {
			continue
		}
		if len([]rune(image)) > 500 {
			return nil, errors.New("图片路径长度过长")
		}
		cleaned = append(cleaned, image)
	}
	return cleaned, nil
}

func cleanReviewTags(tags []string) ([]string, error) {
	if len(tags) > 6 {
		return nil, errors.New("最多选择6个体验标签")
	}
	cleaned := make([]string, 0, len(tags))
	seen := map[string]bool{}
	for _, tag := range tags {
		tag = strings.TrimSpace(tag)
		if tag == "" || seen[tag] {
			continue
		}
		if _, ok := validCanteenTags[tag]; !ok {
			return nil, errors.New("评价标签不合法")
		}
		seen[tag] = true
		cleaned = append(cleaned, tag)
	}
	return cleaned, nil
}

func encodeStringList(values []string) string {
	data, _ := json.Marshal(values)
	return string(data)
}

func decodeStringList(raw string) []string {
	var values []string
	if strings.TrimSpace(raw) == "" {
		return values
	}
	if err := json.Unmarshal([]byte(raw), &values); err != nil {
		return values
	}
	return values
}

func lastReviewID(review *models.CanteenReviewEvent) uint {
	if review == nil {
		return 0
	}
	return review.ID
}

// ensureLegacyReviewEvent 在用户第一次进入 V2 时把旧 /rate 摘要复制成独立历史事件。
// 该事件只用于保留历史、访问次数和旧客户端兼容，不参与 V2 五维有效评分。
func ensureLegacyReviewEvent(tx *gorm.DB, canteenID, userID uint) error {
	var legacyEvent models.CanteenReviewEvent
	if err := tx.Where("canteen_id = ? AND user_id = ? AND score_version = ?", canteenID, userID, 1).
		First(&legacyEvent).Error; err == nil {
		return nil
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return err
	}

	var rating models.CanteenRating
	if err := tx.Where("canteen_id = ? AND user_id = ? AND (status = ? OR status IS NULL OR status = '')",
		canteenID, userID, models.ReviewEventStatusActive).First(&rating).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil
		}
		return err
	}
	if rating.ScoreVersion >= 2 {
		return nil
	}
	createdAt := rating.CreatedAt
	if createdAt.IsZero() {
		createdAt = rating.UpdatedAt
	}
	if createdAt.IsZero() {
		createdAt = time.Now()
	}
	updatedAt := rating.UpdatedAt
	if updatedAt.IsZero() {
		updatedAt = createdAt
	}
	return tx.Create(&models.CanteenReviewEvent{
		CanteenID: canteenID, UserID: userID,
		OverallScore: float64(rating.Star), Comment: rating.Comment, Images: rating.Images, Tags: rating.Tags,
		Status: models.ReviewEventStatusActive, ScoreVersion: 1, CreatedAt: createdAt, UpdatedAt: updatedAt,
	}).Error
}

func recomputeCanteenUserSummary(tx *gorm.DB, canteenID, userID uint) error {
	var events []models.CanteenReviewEvent
	if err := tx.Where("canteen_id = ? AND user_id = ? AND status = ?", canteenID, userID, models.ReviewEventStatusActive).
		Order("created_at DESC, id DESC").Find(&events).Error; err != nil {
		return err
	}
	effective := services.ComputeEffectiveUserRating(events)
	var summary models.CanteenRating
	err := tx.Where("canteen_id = ? AND user_id = ?", canteenID, userID).First(&summary).Error
	if effective.UsedEventCount == 0 {
		var legacy *models.CanteenReviewEvent
		for i := range events {
			if events[i].ScoreVersion == 1 {
				legacy = &events[i]
				break
			}
		}
		if legacy != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				summary = models.CanteenRating{CanteenID: canteenID, UserID: userID}
			} else if err != nil {
				return err
			}
			summary.Star = int(math.Round(legacy.OverallScore))
			summary.EffectiveScore = 0
			summary.TasteScore, summary.ValueScore, summary.QueueScore = 0, 0, 0
			summary.HygieneScore, summary.ServiceScore = 0, 0
			summary.ReviewEventCount = effective.TotalEventCount
			summary.LatestReviewEventID = nil
			summary.ScoreVersion = 1
			summary.Comment, summary.Images, summary.Tags = legacy.Comment, legacy.Images, legacy.Tags
			summary.UpdatedAt = time.Now()
			if summary.ID == 0 {
				return tx.Create(&summary).Error
			}
			return tx.Save(&summary).Error
		}
		// 旧 /rate 摘要没有对应历史事件，继续保留；V2 摘要则必须移除，避免隐藏评价继续参与聚合。
		if errors.Is(err, gorm.ErrRecordNotFound) || summary.ScoreVersion < 2 {
			return nil
		}
		if err != nil {
			return err
		}
		return tx.Delete(&summary).Error
	}
	if errors.Is(err, gorm.ErrRecordNotFound) {
		summary = models.CanteenRating{CanteenID: canteenID, UserID: userID}
	} else if err != nil {
		return err
	}
	var latest models.CanteenReviewEvent
	_ = tx.First(&latest, effective.LatestEventID).Error
	summary.Star = int(math.Round(effective.Overall))
	summary.EffectiveScore = effective.Overall
	summary.TasteScore, summary.ValueScore, summary.QueueScore = effective.Taste, effective.Value, effective.Queue
	summary.HygieneScore, summary.ServiceScore = effective.Hygiene, effective.Service
	summary.ReviewEventCount, summary.LatestReviewEventID = effective.TotalEventCount, &effective.LatestEventID
	summary.ScoreVersion = 2
	summary.Comment, summary.Images, summary.Tags = latest.Comment, latest.Images, latest.Tags
	summary.UpdatedAt = time.Now()
	if summary.ID == 0 {
		return tx.Create(&summary).Error
	}
	return tx.Save(&summary).Error
}

func uniqueReviewDishIDs(ids ...[]uint) []uint {
	seen := make(map[uint]struct{})
	result := make([]uint, 0, 3)
	for _, group := range ids {
		for _, id := range group {
			if id == 0 {
				continue
			}
			if _, ok := seen[id]; ok {
				continue
			}
			seen[id] = struct{}{}
			result = append(result, id)
		}
	}
	return result
}

// resolveReviewDishIDs 将明确选择的 dish_ids、已填写评分的菜品以及旧客户端的菜名
// 解析为同一组实体。模糊候选不会在这里自动合并；未知菜名直接报错，避免“界面显示了但
// 服务端静默丢弃”的假成功。
func (h *CanteenHandler) resolveReviewDishIDs(tx *gorm.DB, canteenID uint, ids []uint, names []string, reviews []reviewDishInput) ([]uint, error) {
	result := uniqueReviewDishIDs(ids)
	for _, input := range reviews {
		result = uniqueReviewDishIDs(result, []uint{input.DishID})
	}
	for _, rawName := range names {
		name := strings.TrimSpace(rawName)
		if name == "" {
			continue
		}
		normalized := utils.NormalizeDishName(name)
		var dish models.CanteenDish
		if err := tx.Where("canteen_id = ? AND normalized_name = ? AND status = ?", canteenID, normalized, models.DishStatusActive).First(&dish).Error; err != nil {
			return nil, fmt.Errorf("%w: 推荐菜品尚未收录，请先上传带照片的菜品投稿并等待审核", errReviewDishInvalid)
		}
		result = uniqueReviewDishIDs(result, []uint{dish.ID})
	}
	if len(result) > 3 {
		return nil, errors.New("最多选择3道菜品")
	}
	return result, nil
}

// syncDishReviews 同步一条到店评价的菜品关系和可选菜品评分。
// 关系是“推荐/吃过”，评分事件是独立对象；编辑时删除关系、隐藏被移除的评分事件，
// 并为所有受影响菜品重算用户摘要，避免旧评分残留在统计中。
func (h *CanteenHandler) syncDishReviews(tx *gorm.DB, canteenID, userID, reviewEventID uint, selectedIDs []uint, inputs []reviewDishInput) error {
	selected := make(map[uint]struct{}, len(selectedIDs))
	for _, id := range selectedIDs {
		var dish models.CanteenDish
		if err := tx.Where("id = ? AND canteen_id = ? AND status = ?", id, canteenID, models.DishStatusActive).First(&dish).Error; err != nil {
			return fmt.Errorf("%w: 菜品不存在或已下架", errReviewDishInvalid)
		}
		selected[id] = struct{}{}
	}

	var oldRelations []models.CanteenReviewEventDish
	if err := tx.Where("review_event_id = ?", reviewEventID).Find(&oldRelations).Error; err != nil {
		return err
	}
	affected := make(map[uint]struct{}, len(oldRelations)+len(selected))
	for _, relation := range oldRelations {
		affected[relation.DishID] = struct{}{}
		if _, keep := selected[relation.DishID]; !keep {
			if err := tx.Delete(&relation).Error; err != nil {
				return err
			}
		}
	}
	for id := range selected {
		affected[id] = struct{}{}
		var relation models.CanteenReviewEventDish
		err := tx.Where("review_event_id = ? AND dish_id = ?", reviewEventID, id).First(&relation).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			if err := tx.Create(&models.CanteenReviewEventDish{ReviewEventID: reviewEventID, DishID: id, Relation: models.DishReviewRelationAte}).Error; err != nil {
				return err
			}
		} else if err != nil {
			return err
		}
	}

	byDish := make(map[uint]reviewDishInput, len(inputs))
	for _, input := range inputs {
		if input.DishID == 0 {
			continue
		}
		if _, selected := selected[input.DishID]; !selected {
			return fmt.Errorf("%w: 菜品评分必须属于已选择的推荐菜品", errReviewDishInvalid)
		}
		if !services.ValidateDishScores(services.DishScores{Taste: input.TasteScore, Value: input.ValueScore, Portion: input.PortionScore}) {
			return fmt.Errorf("%w: 菜品评分均需为1到5分", errReviewDishInvalid)
		}
		if len([]rune(input.Comment)) > 500 {
			return fmt.Errorf("%w: 菜品评价文字不能超过500字", errReviewDishInvalid)
		}
		byDish[input.DishID] = input
	}

	var existing []models.CanteenDishReviewEvent
	if err := tx.Where("canteen_review_event_id = ?", reviewEventID).Find(&existing).Error; err != nil {
		return err
	}
	existingByDish := make(map[uint]models.CanteenDishReviewEvent, len(existing))
	for _, event := range existing {
		existingByDish[event.DishID] = event
		affected[event.DishID] = struct{}{}
	}
	for dishID, input := range byDish {
		if event, ok := existingByDish[dishID]; ok {
			event.TasteScore, event.ValueScore, event.PortionScore = input.TasteScore, input.ValueScore, input.PortionScore
			event.OverallScore = services.ComputeDishOverall(services.DishScores{Taste: input.TasteScore, Value: input.ValueScore, Portion: input.PortionScore})
			event.Comment, event.Status, event.UpdatedAt = input.Comment, models.ReviewEventStatusActive, time.Now()
			if err := tx.Save(&event).Error; err != nil {
				return err
			}
			continue
		}
		event := models.CanteenDishReviewEvent{
			DishID: dishID, UserID: userID, TasteScore: input.TasteScore, ValueScore: input.ValueScore, PortionScore: input.PortionScore,
			OverallScore: services.ComputeDishOverall(services.DishScores{Taste: input.TasteScore, Value: input.ValueScore, Portion: input.PortionScore}),
			Comment:      input.Comment, Status: models.ReviewEventStatusActive, ScoreVersion: 1, CanteenReviewEventID: &reviewEventID,
		}
		if err := tx.Create(&event).Error; err != nil {
			return err
		}
	}
	for _, event := range existing {
		if _, keep := byDish[event.DishID]; !keep && event.Status == models.ReviewEventStatusActive {
			if err := tx.Model(&models.CanteenDishReviewEvent{}).Where("id = ?", event.ID).Update("status", models.ReviewEventStatusHidden).Error; err != nil {
				return err
			}
		}
	}
	for dishID := range affected {
		if err := recomputeDishUserSummary(tx, dishID, userID); err != nil {
			return err
		}
	}
	return nil
}

func recomputeDishUserSummary(tx *gorm.DB, dishID, userID uint) error {
	var events []models.CanteenDishReviewEvent
	if err := tx.Where("dish_id = ? AND user_id = ? AND status = ?", dishID, userID, models.ReviewEventStatusActive).
		Order("created_at DESC, id DESC").Find(&events).Error; err != nil {
		return err
	}
	if len(events) == 0 {
		return tx.Where("dish_id = ? AND user_id = ?", dishID, userID).
			Delete(&models.CanteenDishRatingSummary{}).Error
	}
	active := make([]models.CanteenDishReviewEvent, 0, len(events))
	for _, event := range events {
		if event.OverallScore <= 0 {
			event.OverallScore = services.ComputeDishOverall(services.DishScores{Taste: event.TasteScore, Value: event.ValueScore, Portion: event.PortionScore})
		}
		active = append(active, event)
	}
	totalEventCount := len(active)
	if len(active) > 3 {
		active = active[:3]
	}
	weights := []float64{0.6, 0.3, 0.1}
	weightSum := 0.0
	for i := range active {
		weightSum += weights[i]
	}
	var summary models.CanteenDishRatingSummary
	err := tx.Where("dish_id = ? AND user_id = ?", dishID, userID).First(&summary).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		summary = models.CanteenDishRatingSummary{DishID: dishID, UserID: userID}
	} else if err != nil {
		return err
	}
	summary.EffectiveScore = 0
	summary.TasteScore = 0
	summary.ValueScore = 0
	summary.PortionScore = 0
	summary.LatestReviewEventID = nil
	for i, event := range active {
		weight := weights[i] / weightSum
		summary.EffectiveScore += event.OverallScore * weight
		summary.TasteScore += float64(event.TasteScore) * weight
		summary.ValueScore += float64(event.ValueScore) * weight
		summary.PortionScore += float64(event.PortionScore) * weight
		if i == 0 {
			summary.LatestReviewEventID = &event.ID
		}
	}
	summary.ReviewEventCount = totalEventCount
	summary.UpdatedAt = time.Now()
	if summary.ID == 0 {
		return tx.Create(&summary).Error
	}
	return tx.Save(&summary).Error
}

func populateReviewPublicFields(db *gorm.DB, review *models.CanteenReviewEvent) {
	if review.User != nil {
		review.UserName, review.UserAvatar, review.CreditScore = review.User.Nickname, review.User.Avatar, review.User.CreditScore
		review.CreditWeight = services.ComputeCreditWeight(review.CreditScore)
	} else {
		var user models.User
		if db.Select("id", "nickname", "avatar", "credit_score").First(&user, review.UserID).Error == nil {
			review.UserName, review.UserAvatar, review.CreditScore = user.Nickname, user.Avatar, user.CreditScore
			review.CreditWeight = services.ComputeCreditWeight(user.CreditScore)
		}
	}
	var count int64
	db.Model(&models.CanteenReviewEvent{}).Where("canteen_id = ? AND user_id = ? AND status = ?", review.CanteenID, review.UserID, models.ReviewEventStatusActive).Count(&count)
	review.HistoryCount = int(count)
}

func populateDishReviewPublicFields(db *gorm.DB, review *models.CanteenDishReviewEvent) {
	if review.User != nil {
		review.UserName, review.UserAvatar, review.CreditScore = review.User.Nickname, review.User.Avatar, review.User.CreditScore
		review.CreditWeight = services.ComputeCreditWeight(review.CreditScore)
		return
	}
	var user models.User
	if db.Select("id", "nickname", "avatar", "credit_score").First(&user, review.UserID).Error == nil {
		review.UserName, review.UserAvatar, review.CreditScore = user.Nickname, user.Avatar, user.CreditScore
		review.CreditWeight = services.ComputeCreditWeight(user.CreditScore)
	}
}

func runeEditDistance(a, b string) int {
	ar, br := []rune(a), []rune(b)
	prev := make([]int, len(br)+1)
	for j := range prev {
		prev[j] = j
	}
	for i, ra := range ar {
		cur := make([]int, len(br)+1)
		cur[0] = i + 1
		for j, rb := range br {
			cost := 0
			if ra != rb {
				cost = 1
			}
			cur[j+1] = minEditInt(cur[j]+1, prev[j+1]+1, prev[j]+cost)
		}
		prev = cur
	}
	return prev[len(br)]
}

func minEditInt(values ...int) int {
	minimum := values[0]
	for _, value := range values[1:] {
		if value < minimum {
			minimum = value
		}
	}
	return minimum
}
