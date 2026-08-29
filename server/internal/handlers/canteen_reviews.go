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

var errReviewDishConflict = errors.New("review_dish_conflict")
var errReviewDishPendingLimit = errors.New("review_dish_pending_limit")

type reviewDishInput struct {
	DishID       uint   `json:"dish_id"`
	DishName     string `json:"dish_name,omitempty"`
	TasteScore   int    `json:"taste_score"`
	ValueScore   int    `json:"value_score"`
	PortionScore int    `json:"portion_score"`
	Comment      string `json:"comment"`
	PhotoFileIDs []uint `json:"photo_file_ids,omitempty"`
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
	DishIDs     []uint            `json:"dish_ids"`
	DishNames   []string          `json:"dish_names"`
	DishReviews []reviewDishInput `json:"dish_reviews"`
	// Dishes 是新客户端的一次提交载荷，携带菜名、可选三维评分和绑定的实拍 file_id。
	// 旧字段继续保留，便于旧版本客户端平滑升级。
	Dishes        []reviewDishInput `json:"dishes"`
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
	if len(input.Dishes) > 1 || len(input.DishReviews) > 1 || len(input.DishIDs) > 1 || len(input.DishNames) > 1 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_review_dish", "error": "每条评价只能选择1道菜品"})
		return
	}

	var saved models.CanteenReviewEvent
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
		resolvedDishes, selectedDishIDs, err := h.resolveReviewDishInputs(tx, cid, userID, input.DishIDs, input.DishNames, input.DishReviews, input.Dishes)
		if err != nil {
			return err
		}
		if err := h.syncDishReviews(tx, cid, userID, saved.ID, selectedDishIDs, resolvedDishes); err != nil {
			return err
		}
		if err := h.syncDishPhotos(tx, userID, saved.ID, resolvedDishes); err != nil {
			return err
		}
		if err := recomputeCanteenUserSummary(tx, cid, userID); err != nil {
			return err
		}
		return services.ClaimPublicImagePathsForUser(tx, userID, cleanedImages...)
	})
	if err != nil {
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
		if errors.Is(err, errReviewDishConflict) {
			c.JSON(http.StatusConflict, gin.H{"code": "review_dish_conflict", "error": err.Error()})
			return
		}
		if errors.Is(err, errReviewDishPendingLimit) {
			c.JSON(http.StatusConflict, gin.H{"code": "dish_pending_limit", "error": err.Error()})
			return
		}
		if errors.Is(err, services.ErrInvalidImageFileReference) {
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_review_image", "error": err.Error()})
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
	if len(input.Dishes) > 1 || len(input.DishReviews) > 1 || len(input.DishIDs) > 1 || len(input.DishNames) > 1 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_review_dish", "error": "每条评价只能选择1道菜品"})
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
		// 编辑也必须与商家下架串行化；否则下架与保存并发时可能留下半条公开链路。
		if _, err := lockActiveCanteen(tx, review.CanteenID); err != nil {
			return err
		}
		var latest models.CanteenReviewEvent
		// 只能修改用户在该店创建的最新 V2 事件；status 仅决定该事件当前是否可操作。
		if err := tx.Where("canteen_id = ? AND user_id = ? AND (score_version >= ? OR score_version = ?)", review.CanteenID, review.UserID, 2, 0).
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
		resolvedDishes, selectedDishIDs, err := h.resolveReviewDishInputs(tx, review.CanteenID, userID, input.DishIDs, input.DishNames, input.DishReviews, input.Dishes)
		if err != nil {
			return err
		}
		if err := h.syncDishReviews(tx, review.CanteenID, review.UserID, review.ID, selectedDishIDs, resolvedDishes); err != nil {
			return err
		}
		if err := h.syncDishPhotos(tx, userID, review.ID, resolvedDishes); err != nil {
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
		case errors.Is(err, errCanteenOffline):
			c.JSON(http.StatusConflict, gin.H{"code": "canteen_offline", "error": "该店当前已下架，暂不能修改评价"})
		case errors.Is(err, errReviewNotLatest):
			c.JSON(http.StatusConflict, gin.H{"code": "review_not_latest", "error": "只能修改最近一次评价，请刷新后重试"})
		case errors.Is(err, errReviewDishConflict):
			c.JSON(http.StatusConflict, gin.H{"code": "review_dish_conflict", "error": err.Error()})
		case errors.Is(err, errReviewDishPendingLimit):
			c.JSON(http.StatusConflict, gin.H{"code": "dish_pending_limit", "error": err.Error()})
		case errors.Is(err, errReviewConflict):
			c.JSON(http.StatusConflict, gin.H{"code": "review_conflict", "error": "评价已在其他设备更新，请刷新后重试", "remote_updated_at": review.UpdatedAt})
		case errors.Is(err, errReviewDishInvalid):
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_review_dish", "error": err.Error()})
		case errors.Is(err, services.ErrInvalidImageFileReference):
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_review_image", "error": err.Error()})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "保存评价失败"})
		}
		return
	}
	populateReviewPublicFields(h.db, &review)
	canteenDiscoveryCache.Invalidate()
	c.JSON(http.StatusOK, gin.H{"message": "评价已保存", "review": review})
}

// DeleteReview 软删除用户自己的 V2 到店评价，并同步清理关联菜品评价与摘要。
// DELETE /api/canteens/reviews/:reviewId
func (h *CanteenHandler) DeleteReview(c *gin.Context) {
	reviewID, err := strconv.ParseUint(c.Param("reviewId"), 10, 64)
	if err != nil || reviewID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效评价ID"})
		return
	}
	userID, ok := authenticatedUserID(c)
	if !ok {
		return
	}

	alreadyDeleted := false
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var review models.CanteenReviewEvent
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&review, uint(reviewID)).Error; err != nil {
			return err
		}
		if review.UserID != userID {
			return errReviewForbidden
		}
		if review.Status == models.ReviewEventStatusDeleted {
			alreadyDeleted = true
			return nil
		}
		if review.Status != models.ReviewEventStatusActive {
			return errReviewNotActive
		}

		oldImageFileIDs, err := services.FileIDsByPublicPaths(tx, decodeStringList(review.Images)...)
		if err != nil {
			return err
		}
		// 菜品实拍属于独立社区资产：已审核图片脱离评价后继续公开；尚未审核的
		// 评价证据随评价删除并归档，之后用户仍可重新提交。
		var boundPhotos []models.CanteenDishPhoto
		if tx.Migrator().HasTable(&models.CanteenDishPhoto{}) {
			if err := tx.Where("review_event_id = ?", review.ID).Find(&boundPhotos).Error; err != nil {
				return err
			}
		}
		for _, photo := range boundPhotos {
			if photo.Status == models.DishPhotoStatusApproved {
				if err := tx.Model(&models.CanteenDishPhoto{}).Where("id = ?", photo.ID).Update("review_event_id", nil).Error; err != nil {
					return err
				}
				continue
			}
			if err := tx.Model(&models.CanteenDishPhoto{}).Where("id = ?", photo.ID).Updates(map[string]interface{}{
				"status": models.DishPhotoStatusArchived, "review_event_id": nil, "reject_reason": "评价已删除",
			}).Error; err != nil {
				return err
			}
			if err := services.ReconcileFilePublicAccess(tx, photo.FileID); err != nil {
				return err
			}
		}

		var linked []models.CanteenDishReviewEvent
		if err := tx.Where("canteen_review_event_id = ?", review.ID).Find(&linked).Error; err != nil {
			return err
		}
		affectedDishIDs := make(map[uint]struct{}, len(linked))
		for _, dishReview := range linked {
			affectedDishIDs[dishReview.DishID] = struct{}{}
		}
		var reviewRelations []models.CanteenReviewEventDish
		if err := tx.Where("review_event_id = ?", review.ID).Find(&reviewRelations).Error; err != nil {
			return err
		}
		for _, relation := range reviewRelations {
			affectedDishIDs[relation.DishID] = struct{}{}
		}
		if len(reviewRelations) > 0 {
			if err := tx.Where("review_event_id = ?", review.ID).Delete(&models.CanteenReviewEventDish{}).Error; err != nil {
				return err
			}
		}
		if len(linked) > 0 {
			if err := tx.Model(&models.CanteenDishReviewEvent{}).
				Where("canteen_review_event_id = ?", review.ID).
				Update("status", models.ReviewEventStatusDeleted).Error; err != nil {
				return err
			}
		}
		if err := tx.Model(&models.CanteenReviewEvent{}).
			Where("id = ?", review.ID).
			Update("status", models.ReviewEventStatusDeleted).Error; err != nil {
			return err
		}
		if err := recomputeCanteenUserSummary(tx, review.CanteenID, review.UserID); err != nil {
			return err
		}
		for dishID := range affectedDishIDs {
			if err := recomputeDishUserSummary(tx, dishID, review.UserID); err != nil {
				return err
			}
		}
		for dishID := range affectedDishIDs {
			var dish models.CanteenDish
			if err := tx.First(&dish, dishID).Error; err != nil {
				continue
			}
			if dish.Status != models.DishStatusPending {
				continue
			}
			var evidence int64
			if err := tx.Model(&models.CanteenDishPhoto{}).
				Where("dish_id = ? AND status IN ?", dish.ID, []string{models.DishPhotoStatusPending, models.DishPhotoStatusApproved}).Count(&evidence).Error; err != nil {
				return err
			}
			var otherRelations int64
			if err := tx.Model(&models.CanteenReviewEventDish{}).
				Where("dish_id = ?", dish.ID).Count(&otherRelations).Error; err != nil {
				return err
			}
			if evidence == 0 && otherRelations == 0 {
				if err := tx.Model(&models.CanteenDish{}).Where("id = ?", dish.ID).Updates(map[string]interface{}{
					"status": models.DishStatusArchived, "reject_reason": "唯一评价证据已删除",
				}).Error; err != nil {
					return err
				}
			}
		}
		return services.ReconcileFilePublicAccess(tx, oldImageFileIDs...)
	})
	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "评价不存在"})
		case errors.Is(err, errReviewForbidden):
			c.JSON(http.StatusForbidden, gin.H{"code": "review_forbidden", "error": "只能删除自己的评价"})
		case errors.Is(err, errReviewNotActive):
			c.JSON(http.StatusConflict, gin.H{"code": "review_not_active", "error": "评价当前不可操作"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "删除评价失败"})
		}
		return
	}
	canteenDiscoveryCache.Invalidate()
	c.JSON(http.StatusOK, gin.H{"message": "评价已删除", "already_deleted": alreadyDeleted})
}

// DeleteLegacyRating 软删除旧版 /rate 评价。旧评价没有修改入口，但仍然必须允许用户管理和删除。
// DELETE /api/canteens/ratings/:ratingId
func (h *CanteenHandler) DeleteLegacyRating(c *gin.Context) {
	ratingID, err := strconv.ParseUint(c.Param("ratingId"), 10, 64)
	if err != nil || ratingID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效评价ID"})
		return
	}
	userID, ok := authenticatedUserID(c)
	if !ok {
		return
	}

	alreadyDeleted := false
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var rating models.CanteenRating
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&rating, uint(ratingID)).Error; err != nil {
			return err
		}
		if rating.UserID != userID {
			return errReviewForbidden
		}
		if rating.Status == models.ReviewEventStatusDeleted {
			alreadyDeleted = true
			return nil
		}
		if rating.Status != "" && rating.Status != models.ReviewEventStatusActive {
			return errReviewNotActive
		}

		oldImageFileIDs, err := services.FileIDsByPublicPaths(tx, decodeStringList(rating.Images)...)
		if err != nil {
			return err
		}
		if err := tx.Model(&models.CanteenRating{}).Where("id = ?", rating.ID).
			Update("status", models.ReviewEventStatusDeleted).Error; err != nil {
			return err
		}
		// 若该旧评价曾被 V2 迁移为 score_version=1 的历史事件，同步软删除，
		// 防止它在历史/兼容接口中重新出现。
		if tx.Migrator().HasTable(&models.CanteenReviewEvent{}) {
			if err := tx.Model(&models.CanteenReviewEvent{}).
				Where("canteen_id = ? AND user_id = ? AND score_version = ? AND status = ?", rating.CanteenID, rating.UserID, 1, models.ReviewEventStatusActive).
				Update("status", models.ReviewEventStatusDeleted).Error; err != nil {
				return err
			}
			if err := recomputeCanteenUserSummary(tx, rating.CanteenID, rating.UserID); err != nil {
				return err
			}
		}
		return services.ReconcileFilePublicAccess(tx, oldImageFileIDs...)
	})
	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "评价不存在"})
		case errors.Is(err, errReviewForbidden):
			c.JSON(http.StatusForbidden, gin.H{"code": "review_forbidden", "error": "只能删除自己的评价"})
		case errors.Is(err, errReviewNotActive):
			c.JSON(http.StatusConflict, gin.H{"code": "review_not_active", "error": "评价当前不可操作"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "删除评价失败"})
		}
		return
	}
	canteenDiscoveryCache.Invalidate()
	c.JSON(http.StatusOK, gin.H{"message": "评价已删除", "already_deleted": alreadyDeleted})
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
	viewerID := uint(0)
	if uid, exists := c.Get("user_id"); exists {
		if userID, ok := uid.(uint); ok {
			viewerID = userID
			populateReviewVotes(h.db, events, userID)
		}
	}
	populateReviewDishNamesForViewer(h.db, events, viewerID)
	populateReviewDishPhotosForViewer(h.db, events, viewerID)
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
		return hasReviewImages(review.Images) || len(review.DishPhotos) > 0
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
	if err := h.db.Where("canteen_id = ? AND status = ? AND (score_version >= ? OR score_version = ?)", canteenID, models.ReviewEventStatusActive, 2, 0).
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
	for i := range all {
		populateReviewPublicFields(h.db, &all[i])
	}
	// 评价筛选需要把已审核的菜品实拍也视为“有图”。这里只加载公开资产；
	// 调用方在拿到最终展示列表后会按当前查看者重新补齐自己的 pending/rejected 资产。
	populateReviewDishPhotosForViewer(h.db, all, 0)
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
	if err := h.db.Where("canteen_id = ? AND user_id = ? AND (score_version >= ? OR score_version = ?)", canteenID, userID, 2, 0).
		Order("created_at DESC, id DESC").First(&event).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) || isCanteenReviewSchemaMissing(err) {
			return nil, nil
		}
		return nil, err
	}
	if event.Status != models.ReviewEventStatusActive {
		// 已删除或隐藏的事件不能进入编辑器；创建新评价不再受时间冷却限制。
		return nil, nil
	}

	type selectedDishRow struct {
		DishID       uint   `gorm:"column:dish_id"`
		Name         string `gorm:"column:name"`
		Status       string `gorm:"column:status"`
		RejectReason string `gorm:"column:reject_reason"`
	}
	selectedDishes := make([]selectedDishRow, 0, 3)
	if h.db.Migrator().HasTable(&models.CanteenReviewEventDish{}) {
		if err := h.db.Table("canteen_review_event_dishes AS relation").
			Select("relation.dish_id, dish.name, dish.status, dish.reject_reason").
			Joins("JOIN canteen_dishes AS dish ON dish.id = relation.dish_id").
			Where("relation.review_event_id = ?", event.ID).
			Order("relation.id ASC").Find(&selectedDishes).Error; err != nil && !isCanteenReviewSchemaMissing(err) {
			return nil, err
		}
	}

	dishNames := make(map[uint]string, len(selectedDishes))
	recommendedDishes := make([]map[string]interface{}, 0, len(selectedDishes))
	recommendedDishDetails := make([]map[string]interface{}, 0, len(selectedDishes))
	for _, dish := range selectedDishes {
		dishNames[dish.DishID] = dish.Name
		recommendedDishes = append(recommendedDishes, map[string]interface{}{
			"dish_id": dish.DishID, "name": dish.Name,
		})
		recommendedDishDetails = append(recommendedDishDetails, map[string]interface{}{
			"dish_id": dish.DishID, "name": dish.Name, "status": dish.Status, "reject_reason": dish.RejectReason,
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
		if err := h.db.Where("canteen_review_event_id = ? AND status <> ?", event.ID, models.ReviewEventStatusDeleted).
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
		"review_event_id":          event.ID,
		"id":                       event.ID,
		"canteen_id":               event.CanteenID,
		"user_id":                  event.UserID,
		"star":                     event.OverallScore,
		"overall_score":            event.OverallScore,
		"taste_score":              event.TasteScore,
		"value_score":              event.ValueScore,
		"queue_score":              event.QueueScore,
		"hygiene_score":            event.HygieneScore,
		"service_score":            event.ServiceScore,
		"comment":                  event.Comment,
		"images":                   event.Images,
		"tags":                     event.Tags,
		"score_version":            event.ScoreVersion,
		"created_at":               event.CreatedAt,
		"updated_at":               event.UpdatedAt,
		"recommended_dishes":       recommendedDishes,
		"recommended_dish_details": recommendedDishDetails,
		"dish_reviews":             dishReviews,
		"dish_photos":              h.loadReviewDishPhotos(event.ID),
	}, nil
}

// loadReviewDishPhotos 返回评价编辑器需要的图片-菜品绑定，包含 pending/rejected，
// approved 图片也会保留用于展示和“删除评价但保留公共资产”的判断。
func (h *CanteenHandler) loadReviewDishPhotos(reviewEventID uint) []map[string]interface{} {
	rows := make([]map[string]interface{}, 0)
	var photos []models.CanteenDishPhoto
	if err := h.db.Where("review_event_id = ?", reviewEventID).Order("id ASC").Find(&photos).Error; err != nil {
		return rows
	}
	for _, photo := range photos {
		item := map[string]interface{}{
			"id": photo.ID, "dish_id": photo.DishID, "file_id": photo.FileID,
			"status": photo.Status, "reject_reason": photo.RejectReason,
			"created_at": photo.CreatedAt,
		}
		var file models.File
		if err := h.db.Select("path").First(&file, photo.FileID).Error; err == nil {
			item["image"] = file.Path
		}
		var dish models.CanteenDish
		if err := h.db.Select("name").First(&dish, photo.DishID).Error; err == nil {
			item["dish_name"] = dish.Name
		}
		rows = append(rows, item)
	}
	return rows
}

// GetReviewEditContext 返回单条评价的权威编辑上下文。所有客户端编辑入口都应先读取此接口，
// 不允许从评价列表的裁剪字段拼装保存请求。
// GET /api/canteens/reviews/:reviewId/edit-context
func (h *CanteenHandler) GetReviewEditContext(c *gin.Context) {
	reviewID, err := strconv.ParseUint(c.Param("reviewId"), 10, 64)
	if err != nil || reviewID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效评价ID"})
		return
	}
	userID, ok := authenticatedUserID(c)
	if !ok {
		return
	}
	var event models.CanteenReviewEvent
	if err := h.db.Where("id = ? AND user_id = ?", reviewID, userID).First(&event).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "评价不存在"})
		return
	}
	if event.Status != models.ReviewEventStatusActive {
		c.JSON(http.StatusConflict, gin.H{"code": "review_not_active", "error": "该评价当前不可编辑"})
		return
	}
	payload, err := h.loadMyLatestReviewPayload(event.CanteenID, userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取评价编辑上下文失败"})
		return
	}
	if payload == nil || fmt.Sprint(payload["review_event_id"]) != fmt.Sprint(event.ID) {
		c.JSON(http.StatusConflict, gin.H{"code": "review_not_latest", "error": "只能编辑最近一次评价，请刷新后重试"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"review": payload})
}

// buildReviewAction 返回详情页创建/编辑入口的服务端权威状态。
// Legacy 摘要只代表历史兼容数据，不会被标记为可编辑的 V2 事件。
func (h *CanteenHandler) buildReviewAction(canteenID, userID uint) (map[string]interface{}, error) {
	action := map[string]interface{}{
		"can_create":       true,
		"can_edit_latest":  false,
		"latest_review_id": nil,
	}
	if !h.db.Migrator().HasTable(&models.CanteenReviewEvent{}) {
		return action, nil
	}

	var latest models.CanteenReviewEvent
	err := h.db.Where(
		"canteen_id = ? AND user_id = ? AND (score_version >= ? OR score_version = ?)",
		canteenID, userID, 2, 0,
	).Order("created_at DESC, id DESC").First(&latest).Error
	if errors.Is(err, gorm.ErrRecordNotFound) || isCanteenReviewSchemaMissing(err) {
		return action, nil
	}
	if err != nil {
		return nil, err
	}

	action["latest_review_id"] = latest.ID
	action["can_edit_latest"] = latest.Status == models.ReviewEventStatusActive
	return action, nil
}

func populateReviewDishNames(db *gorm.DB, reviews []models.CanteenReviewEvent) {
	populateReviewDishNamesForViewer(db, reviews, 0)
}

// populateReviewDishNamesForViewer 按查看者过滤菜品关系：active/pending 可用于公共
// 评价回显，rejected/archived/hidden/merged 只允许评价作者看见，避免把后台否决的
// 菜名伪装成公共菜品或继续显示“待收录”。
func populateReviewDishNamesForViewer(db *gorm.DB, reviews []models.CanteenReviewEvent, viewerID uint) {
	for i := range reviews {
		reviews[i].RecommendedDishNames = nil
		reviews[i].RecommendedDishDetails = nil
	}
	ids := make([]uint, 0, len(reviews))
	ownerByReview := make(map[uint]uint, len(reviews))
	for _, review := range reviews {
		if review.ID != 0 {
			ids = append(ids, review.ID)
			ownerByReview[review.ID] = review.UserID
		}
	}
	if len(ids) == 0 {
		return
	}
	type dishNameRow struct {
		ReviewEventID uint   `gorm:"column:review_event_id"`
		DishID        uint   `gorm:"column:dish_id"`
		Name          string `gorm:"column:name"`
		Status        string `gorm:"column:status"`
		RejectReason  string `gorm:"column:reject_reason"`
	}
	var rows []dishNameRow
	if err := db.Table("canteen_review_event_dishes AS r").
		Select("r.review_event_id, r.dish_id, d.name, d.status, d.reject_reason").
		Joins("JOIN canteen_dishes d ON d.id = r.dish_id").
		Where("r.review_event_id IN ?", ids).
		Order("r.id ASC").Find(&rows).Error; err != nil {
		return
	}
	byReview := make(map[uint][]string, len(rows))
	detailsByReview := make(map[uint][]map[string]interface{}, len(rows))
	for _, row := range rows {
		isPublic := row.Status == models.DishStatusActive
		isOwner := viewerID != 0 && ownerByReview[row.ReviewEventID] == viewerID
		if !isPublic && !isOwner {
			continue
		}
		byReview[row.ReviewEventID] = append(byReview[row.ReviewEventID], row.Name)
		detailsByReview[row.ReviewEventID] = append(detailsByReview[row.ReviewEventID], map[string]interface{}{
			"dish_id": row.DishID, "name": row.Name, "status": row.Status, "reject_reason": row.RejectReason,
		})
	}
	for i := range reviews {
		reviews[i].RecommendedDishNames = byReview[reviews[i].ID]
		reviews[i].RecommendedDishDetails = detailsByReview[reviews[i].ID]
	}
}

// populateReviewDishPhotosForViewer 回显评价绑定的菜品实拍。approved 是公共资产；
// pending/rejected/archived 仅返回给评价作者，使“我的评价/我的贡献”可以追踪而不泄露
// 未审核图片。菜品被隐藏或合并后，公共图片也不再从评价流暴露。
func populateReviewDishPhotosForViewer(db *gorm.DB, reviews []models.CanteenReviewEvent, viewerID uint) {
	for i := range reviews {
		reviews[i].DishPhotos = nil
	}
	if len(reviews) == 0 || !db.Migrator().HasTable(&models.CanteenDishPhoto{}) ||
		!db.Migrator().HasTable(&models.CanteenReviewEvent{}) ||
		!db.Migrator().HasTable(&models.CanteenDish{}) {
		return
	}
	ids := make([]uint, 0, len(reviews))
	indexByReview := make(map[uint]int, len(reviews))
	for i, review := range reviews {
		if review.ID == 0 {
			continue
		}
		ids = append(ids, review.ID)
		indexByReview[review.ID] = i
	}
	if len(ids) == 0 {
		return
	}
	type dishPhotoRow struct {
		ID            uint      `gorm:"column:id"`
		ReviewEventID uint      `gorm:"column:review_event_id"`
		DishID        uint      `gorm:"column:dish_id"`
		DishName      string    `gorm:"column:dish_name"`
		FileID        uint      `gorm:"column:file_id"`
		Image         string    `gorm:"column:image"`
		Status        string    `gorm:"column:status"`
		RejectReason  string    `gorm:"column:reject_reason"`
		SortOrder     int       `gorm:"column:sort_order"`
		CreatedAt     time.Time `gorm:"column:created_at"`
		DishStatus    string    `gorm:"column:dish_status"`
		ReviewUserID  uint      `gorm:"column:review_user_id"`
	}
	query := db.Table("canteen_dish_photos AS p").
		Select("p.id, p.review_event_id, p.dish_id, d.name AS dish_name, p.file_id, f.path AS image, p.status, p.reject_reason, p.sort_order, p.created_at, d.status AS dish_status, e.user_id AS review_user_id").
		Joins("JOIN canteen_review_events e ON e.id = p.review_event_id").
		Joins("JOIN canteen_dishes d ON d.id = p.dish_id").
		Joins("JOIN files f ON f.id = p.file_id").
		Where("p.review_event_id IN ?", ids)
	if viewerID == 0 {
		query = query.Where("p.status = ? AND d.status = ?", models.DishPhotoStatusApproved, models.DishStatusActive)
	} else {
		query = query.Where("(p.status = ? AND d.status = ?) OR e.user_id = ?", models.DishPhotoStatusApproved, models.DishStatusActive, viewerID)
	}
	var rows []dishPhotoRow
	if err := query.Order("p.review_event_id, p.sort_order, p.created_at, p.id").Find(&rows).Error; err != nil {
		return
	}
	for _, row := range rows {
		index, ok := indexByReview[row.ReviewEventID]
		if !ok {
			continue
		}
		reviews[index].DishPhotos = append(reviews[index].DishPhotos, map[string]interface{}{
			"id": row.ID, "review_event_id": row.ReviewEventID, "dish_id": row.DishID,
			"dish_name": row.DishName, "file_id": row.FileID, "image": row.Image,
			"status": row.Status, "reject_reason": row.RejectReason,
			"sort_order": row.SortOrder, "created_at": row.CreatedAt,
		})
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
	var latestEvent models.CanteenReviewEvent
	_ = h.db.Where("canteen_id = ? AND user_id = ? AND (score_version >= ? OR score_version = ?)", cid, userID, 2, 0).
		Order("created_at DESC, id DESC").First(&latestEvent).Error
	var canteen models.Canteen
	_ = h.db.Select("id", "operating_status").First(&canteen, cid).Error
	canteen.NormalizeOperatingStatus()
	for i := range events {
		populateReviewPublicFields(h.db, &events[i])
		events[i].CanDelete = true
		events[i].CanEdit = events[i].ScoreVersion >= 2 &&
			events[i].ID == latestEvent.ID && !canteen.IsOffline
		if events[i].ScoreVersion >= 2 {
			events[i].Source = "v2"
		} else {
			events[i].Source = "legacy"
			var legacy models.CanteenRating
			if err := h.db.Where("canteen_id = ? AND user_id = ? AND (status = ? OR status IS NULL OR status = '')", cid, userID, models.ReviewEventStatusActive).First(&legacy).Error; err == nil {
				events[i].LegacyRatingID = &legacy.ID
			}
		}
	}
	viewerID := uint(0)
	if rawViewerID, exists := c.Get("user_id"); exists {
		viewerID, _ = rawViewerID.(uint)
	}
	populateReviewDishNamesForViewer(h.db, events, viewerID)
	populateReviewDishPhotosForViewer(h.db, events, viewerID)
	c.JSON(http.StatusOK, gin.H{"items": events, "count": len(events)})
}

type myCanteenReviewCursor struct {
	CreatedAt time.Time `json:"created_at"`
	ID        uint      `json:"id"`
}

type myCanteenReviewListItem struct {
	CreatedAt time.Time
	ID        uint
	Payload   map[string]interface{}
}

// GetMyCanteenReviews 返回当前登录用户发布过的全部食堂评价，兼容 V2 与仅存在于旧表的评价。
// GET /api/user/canteen-reviews?limit=20&cursor=...
func (h *CanteenHandler) GetMyCanteenReviews(c *gin.Context) {
	userID, ok := authenticatedUserID(c)
	if !ok {
		return
	}
	limit := 20
	if raw := strings.TrimSpace(c.Query("limit")); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 {
			limit = parsed
		}
	}
	if limit > 50 {
		limit = 50
	}

	var cursor *myCanteenReviewCursor
	if raw := strings.TrimSpace(c.Query("cursor")); raw != "" {
		decoded, err := decodeMyCanteenReviewCursor(raw)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_review_cursor", "error": "评价分页游标无效"})
			return
		}
		cursor = &decoded
	}

	items, err := h.buildMyCanteenReviewItems(userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取我的食堂评价失败"})
		return
	}
	if cursor != nil {
		filtered := items[:0]
		for _, item := range items {
			if item.CreatedAt.Before(cursor.CreatedAt) ||
				(item.CreatedAt.Equal(cursor.CreatedAt) && item.ID < cursor.ID) {
				filtered = append(filtered, item)
			}
		}
		items = filtered
	}

	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
	}
	response := gin.H{"items": make([]map[string]interface{}, 0, len(items)), "count": len(items), "has_more": hasMore}
	for _, item := range items {
		response["items"] = append(response["items"].([]map[string]interface{}), item.Payload)
	}
	if hasMore && len(items) > 0 {
		response["next_cursor"] = encodeMyCanteenReviewCursor(myCanteenReviewCursor{
			CreatedAt: items[len(items)-1].CreatedAt,
			ID:        items[len(items)-1].ID,
		})
	}
	c.JSON(http.StatusOK, response)
}

// GetMyCanteenContributions 返回用户提交的 pending/approved/rejected 菜品与实拍，
// 让投稿不会在评价发布后失去追踪入口。
// GET /api/user/canteen-contributions
func (h *CanteenHandler) GetMyCanteenContributions(c *gin.Context) {
	userID, ok := authenticatedUserID(c)
	if !ok {
		return
	}
	type dishRow struct {
		DishID             uint      `gorm:"column:dish_id"`
		CanteenID          uint      `gorm:"column:canteen_id"`
		CanteenName        string    `gorm:"column:canteen_name"`
		DishName           string    `gorm:"column:dish_name"`
		DishStatus         string    `gorm:"column:dish_status"`
		DishReason         string    `gorm:"column:dish_reason"`
		MergedIntoDishID   *uint     `gorm:"column:merged_into_dish_id"`
		MergedIntoDishName string    `gorm:"column:merged_into_dish_name"`
		CreatedAt          time.Time `gorm:"column:created_at"`
	}
	var dishes []dishRow
	if err := h.db.Table("canteen_dishes d").
		Joins("JOIN canteens c ON c.id = d.canteen_id").
		Joins("LEFT JOIN canteen_dishes merged_target ON merged_target.id = d.merged_into_dish_id").
		Select("d.id AS dish_id, d.canteen_id, c.name AS canteen_name, d.name AS dish_name, d.status AS dish_status, d.reject_reason AS dish_reason, d.merged_into_dish_id, merged_target.name AS merged_into_dish_name, d.created_at").
		Where("d.created_by = ?", userID).Order("d.created_at DESC, d.id DESC").Find(&dishes).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取食堂贡献失败"})
		return
	}
	items := make([]map[string]interface{}, 0)
	seen := make(map[string]struct{})
	seenDishContributions := make(map[uint]struct{}, len(dishes))
	for _, dish := range dishes {
		seenDishContributions[dish.DishID] = struct{}{}
		var photos []models.CanteenDishPhoto
		_ = h.db.Where("dish_id = ? AND user_id = ?", dish.DishID, userID).Order("created_at DESC, id DESC").Find(&photos).Error
		if len(photos) == 0 {
			item := map[string]interface{}{
				"type": "dish", "dish_id": dish.DishID, "dish_name": dish.DishName,
				"canteen_id": dish.CanteenID, "canteen_name": dish.CanteenName,
				"status": dish.DishStatus, "reject_reason": dish.DishReason, "submitted_at": dish.CreatedAt,
			}
			if dish.MergedIntoDishID != nil {
				item["merged_into_dish_id"] = *dish.MergedIntoDishID
				item["merged_into_dish_name"] = dish.MergedIntoDishName
			}
			items = append(items, item)
			continue
		}
		for _, photo := range photos {
			key := fmt.Sprintf("%d:%d", dish.DishID, photo.ID)
			seen[key] = struct{}{}
			item := map[string]interface{}{
				"type": "dish_photo", "photo_id": photo.ID, "dish_id": dish.DishID, "dish_name": dish.DishName, "file_id": photo.FileID,
				"canteen_id": dish.CanteenID, "canteen_name": dish.CanteenName,
				"status": photo.Status, "reject_reason": photo.RejectReason, "submitted_at": photo.CreatedAt,
			}
			var file models.File
			if err := h.db.Select("path").First(&file, photo.FileID).Error; err == nil {
				item["image"] = file.Path
			}
			items = append(items, item)
		}
	}
	// 用户也可以给已有 active 菜补图，此时菜品不是 created_by 本人，只返回其图片贡献。
	var photos []models.CanteenDishPhoto
	_ = h.db.Where("user_id = ?", userID).Order("created_at DESC, id DESC").Find(&photos).Error
	for _, photo := range photos {
		key := fmt.Sprintf("%d:%d", photo.DishID, photo.ID)
		if _, exists := seen[key]; exists {
			continue
		}
		var dish models.CanteenDish
		if h.db.First(&dish, photo.DishID).Error != nil {
			continue
		}
		var canteen models.Canteen
		if h.db.Select("id", "name").First(&canteen, dish.CanteenID).Error != nil {
			continue
		}
		item := map[string]interface{}{
			"type": "dish_photo", "photo_id": photo.ID, "dish_id": dish.ID, "dish_name": dish.Name, "file_id": photo.FileID,
			"canteen_id": dish.CanteenID, "canteen_name": canteen.Name,
			"status": photo.Status, "reject_reason": photo.RejectReason, "submitted_at": photo.CreatedAt,
		}
		var file models.File
		if err := h.db.Select("path").First(&file, photo.FileID).Error; err == nil {
			item["image"] = file.Path
		}
		items = append(items, item)
	}
	// 菜品候选可能由其他同学先创建，但当前用户通过评价关联/补充了它；这类
	// pending/rejected 候选也必须出现在“我的食堂贡献”，否则用户会看不到自己的证据。
	if h.db.Migrator().HasTable(&models.CanteenReviewEventDish{}) {
		var reviewDishes []struct {
			DishID             uint      `gorm:"column:dish_id"`
			CanteenID          uint      `gorm:"column:canteen_id"`
			CanteenName        string    `gorm:"column:canteen_name"`
			DishName           string    `gorm:"column:dish_name"`
			DishStatus         string    `gorm:"column:dish_status"`
			DishReason         string    `gorm:"column:dish_reason"`
			MergedIntoDishID   *uint     `gorm:"column:merged_into_dish_id"`
			MergedIntoDishName string    `gorm:"column:merged_into_dish_name"`
			SubmittedAt        time.Time `gorm:"column:submitted_at"`
		}
		if err := h.db.Table("canteen_review_event_dishes r").
			Joins("JOIN canteen_review_events e ON e.id = r.review_event_id").
			Joins("JOIN canteen_dishes d ON d.id = r.dish_id").
			Joins("JOIN canteens c ON c.id = d.canteen_id").
			Joins("LEFT JOIN canteen_dishes merged_target ON merged_target.id = d.merged_into_dish_id").
			Select("r.dish_id, d.canteen_id, c.name AS canteen_name, d.name AS dish_name, d.status AS dish_status, d.reject_reason AS dish_reason, d.merged_into_dish_id, merged_target.name AS merged_into_dish_name, e.created_at AS submitted_at").
			Where("e.user_id = ? AND e.status = ? AND d.status <> ?", userID, models.ReviewEventStatusActive, models.DishStatusActive).
			Order("e.created_at DESC, r.id DESC").Find(&reviewDishes).Error; err == nil {
			for _, dish := range reviewDishes {
				if _, exists := seenDishContributions[dish.DishID]; exists {
					continue
				}
				seenDishContributions[dish.DishID] = struct{}{}
				item := map[string]interface{}{
					"type": "dish_review", "dish_id": dish.DishID, "dish_name": dish.DishName,
					"canteen_id": dish.CanteenID, "canteen_name": dish.CanteenName,
					"status": dish.DishStatus, "reject_reason": dish.DishReason,
					"submitted_at": dish.SubmittedAt,
				}
				if dish.MergedIntoDishID != nil {
					item["merged_into_dish_id"] = *dish.MergedIntoDishID
					item["merged_into_dish_name"] = dish.MergedIntoDishName
				}
				items = append(items, item)
			}
		}
	}
	c.JSON(http.StatusOK, gin.H{"items": items})
}

func encodeMyCanteenReviewCursor(cursor myCanteenReviewCursor) string {
	payload, _ := json.Marshal(cursor)
	return base64.RawURLEncoding.EncodeToString(payload)
}

func decodeMyCanteenReviewCursor(raw string) (myCanteenReviewCursor, error) {
	var cursor myCanteenReviewCursor
	payload, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return cursor, err
	}
	if err := json.Unmarshal(payload, &cursor); err != nil {
		return cursor, err
	}
	if cursor.CreatedAt.IsZero() || cursor.ID == 0 {
		return cursor, errors.New("incomplete my canteen review cursor")
	}
	return cursor, nil
}

func (h *CanteenHandler) buildMyCanteenReviewItems(userID uint) ([]myCanteenReviewListItem, error) {
	items := make([]myCanteenReviewListItem, 0)
	allV2ByCanteen := make(map[uint]struct{})
	latestV2ByCanteen := make(map[uint]models.CanteenReviewEvent)

	if h.db.Migrator().HasTable(&models.CanteenReviewEvent{}) {
		var allV2 []models.CanteenReviewEvent
		if err := h.db.Where("user_id = ? AND (score_version >= ? OR score_version = ?)", userID, 2, 0).
			Order("created_at DESC, id DESC").Find(&allV2).Error; err != nil && !isCanteenReviewSchemaMissing(err) {
			return nil, err
		}
		populateReviewDishNamesForViewer(h.db, allV2, userID)
		for _, event := range allV2 {
			allV2ByCanteen[event.CanteenID] = struct{}{}
			if _, exists := latestV2ByCanteen[event.CanteenID]; !exists {
				latestV2ByCanteen[event.CanteenID] = event
			}
			if event.Status != models.ReviewEventStatusActive {
				continue
			}
			populateReviewPublicFields(h.db, &event)
			items = append(items, myCanteenReviewListItem{
				CreatedAt: event.CreatedAt,
				ID:        event.ID,
				Payload:   h.myV2ReviewPayload(event, latestV2ByCanteen[event.CanteenID]),
			})
		}
	}

	var ratings []models.CanteenRating
	if h.db.Migrator().HasTable(&models.CanteenRating{}) {
		if err := h.db.Where("user_id = ? AND (status = ? OR status IS NULL OR status = '')", userID, models.ReviewEventStatusActive).
			Order("created_at DESC, id DESC").Find(&ratings).Error; err != nil {
			return nil, err
		}
	}
	for _, rating := range ratings {
		// 已经进入 V2 事件流的食堂以事件历史为准，避免摘要重复返回。
		if _, exists := allV2ByCanteen[rating.CanteenID]; exists {
			continue
		}
		items = append(items, myCanteenReviewListItem{
			CreatedAt: rating.CreatedAt,
			ID:        rating.ID,
			Payload:   h.myLegacyReviewPayload(rating),
		})
	}

	canteenIDs := make([]uint, 0, len(items))
	seenCanteens := make(map[uint]struct{})
	for _, item := range items {
		if id, ok := numericPayloadID(item.Payload["canteen_id"]); ok {
			if _, seen := seenCanteens[id]; !seen {
				seenCanteens[id] = struct{}{}
				canteenIDs = append(canteenIDs, id)
			}
		}
	}
	var canteens []models.Canteen
	if len(canteenIDs) > 0 {
		if err := h.db.Where("id IN ?", canteenIDs).Find(&canteens).Error; err != nil {
			return nil, err
		}
	}
	canteenByID := make(map[uint]models.Canteen, len(canteens))
	for _, canteen := range canteens {
		canteen.NormalizeOperatingStatus()
		canteenByID[canteen.ID] = canteen
	}
	for i := range items {
		canteenID, _ := numericPayloadID(items[i].Payload["canteen_id"])
		canteen := canteenByID[canteenID]
		latest := latestV2ByCanteen[canteenID]
		if items[i].Payload["source"] == "v2" {
			items[i].Payload["can_edit"] = latest.ID == items[i].ID &&
				latest.Status == models.ReviewEventStatusActive &&
				!canteen.IsOffline && latest.ScoreVersion >= 2
		}
		items[i].Payload["canteen"] = map[string]interface{}{
			"id": canteen.ID, "name": canteen.Name, "image": canteen.Image,
			"operating_status": canteen.OperatingStatus, "is_offline": canteen.IsOffline,
		}
	}
	sort.SliceStable(items, func(i, j int) bool {
		if !items[i].CreatedAt.Equal(items[j].CreatedAt) {
			return items[i].CreatedAt.After(items[j].CreatedAt)
		}
		return items[i].ID > items[j].ID
	})
	return items, nil
}

func numericPayloadID(value interface{}) (uint, bool) {
	switch value := value.(type) {
	case uint:
		return value, value > 0
	case int:
		return uint(value), value > 0
	case float64:
		return uint(value), value > 0
	case json.Number:
		parsed, err := strconv.ParseUint(string(value), 10, 64)
		return uint(parsed), err == nil && parsed > 0
	default:
		parsed, err := strconv.ParseUint(fmt.Sprint(value), 10, 64)
		return uint(parsed), err == nil && parsed > 0
	}
}

func (h *CanteenHandler) myV2ReviewPayload(event, latest models.CanteenReviewEvent) map[string]interface{} {
	return map[string]interface{}{
		"id": event.ID, "source": "v2", "review_source": "v2", "canteen_id": event.CanteenID,
		"user_id": event.UserID, "overall_score": event.OverallScore, "star": event.OverallScore,
		"taste_score": event.TasteScore, "value_score": event.ValueScore, "queue_score": event.QueueScore,
		"hygiene_score": event.HygieneScore, "service_score": event.ServiceScore,
		"comment": event.Comment, "images": decodeStringList(event.Images), "tags": decodeStringList(event.Tags),
		"recommended_dishes": event.RecommendedDishNames, "recommended_dish_details": event.RecommendedDishDetails,
		"dish_reviews": h.loadReviewDishReviewPayload(event.ID), "dish_photos": h.loadReviewDishPhotos(event.ID),
		"created_at": event.CreatedAt, "updated_at": event.UpdatedAt,
		"is_edited":  event.UpdatedAt.Sub(event.CreatedAt).Abs() > time.Second,
		"can_edit":   latest.ID == event.ID && event.Status == models.ReviewEventStatusActive,
		"can_delete": event.Status == models.ReviewEventStatusActive,
	}
}

func (h *CanteenHandler) loadReviewDishReviewPayload(reviewEventID uint) []map[string]interface{} {
	var rows []struct {
		DishID       uint   `gorm:"column:dish_id"`
		DishName     string `gorm:"column:dish_name"`
		TasteScore   int    `gorm:"column:taste_score"`
		ValueScore   int    `gorm:"column:value_score"`
		PortionScore int    `gorm:"column:portion_score"`
		Comment      string `gorm:"column:comment"`
	}
	if err := h.db.Table("canteen_dish_review_events AS r").
		Select("r.dish_id, d.name AS dish_name, r.taste_score, r.value_score, r.portion_score, r.comment").
		Joins("JOIN canteen_dishes d ON d.id = r.dish_id").
		Where("r.canteen_review_event_id = ? AND r.status <> ?", reviewEventID, models.ReviewEventStatusDeleted).
		Order("r.id ASC").Scan(&rows).Error; err != nil {
		return []map[string]interface{}{}
	}
	result := make([]map[string]interface{}, 0, len(rows))
	for _, row := range rows {
		result = append(result, map[string]interface{}{
			"dish_id": row.DishID, "dish_name": row.DishName,
			"taste_score": row.TasteScore, "value_score": row.ValueScore,
			"portion_score": row.PortionScore, "comment": row.Comment,
		})
	}
	return result
}

func (h *CanteenHandler) myLegacyReviewPayload(rating models.CanteenRating) map[string]interface{} {
	return map[string]interface{}{
		"id": rating.ID, "source": "legacy", "review_source": "legacy", "canteen_id": rating.CanteenID,
		"user_id": rating.UserID, "overall_score": float64(rating.Star), "star": rating.Star,
		"taste_score": rating.TasteScore, "value_score": rating.ValueScore, "queue_score": rating.QueueScore,
		"hygiene_score": rating.HygieneScore, "service_score": rating.ServiceScore,
		"comment": rating.Comment, "images": decodeStringList(rating.Images), "tags": decodeStringList(rating.Tags),
		"recommended_dishes": rating.RecommendedDishNames, "created_at": rating.CreatedAt, "updated_at": rating.UpdatedAt,
		"is_edited": rating.UpdatedAt.Sub(rating.CreatedAt).Abs() > time.Second,
		"can_edit":  false, "can_delete": true,
	}
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
// 菜品详情的评论正文以主到店评价为准；菜品三维评分只是可选扩展，不能
// 因为没有 CanteenDishReviewEvent 就把主评价评论过滤掉。
func (h *CanteenHandler) GetDishReviews(c *gin.Context) {
	dishID, err := strconv.ParseUint(c.Param("dishId"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效菜品ID"})
		return
	}
	type relationRow struct {
		ReviewEventID uint      `gorm:"column:review_event_id"`
		CreatedAt     time.Time `gorm:"column:created_at"`
	}
	type responseItem struct {
		userID    uint
		createdAt time.Time
		id        uint
		payload   map[string]interface{}
	}

	items := make([]responseItem, 0)
	parentByID := make(map[uint]models.CanteenReviewEvent)
	parentIncluded := make(map[uint]struct{})
	if h.db.Migrator().HasTable(&models.CanteenReviewEvent{}) &&
		h.db.Migrator().HasTable(&models.CanteenReviewEventDish{}) {
		var relations []relationRow
		if err := h.db.Table("canteen_review_event_dishes AS relation").
			Select("relation.review_event_id, review.created_at").
			Joins("JOIN canteen_review_events AS review ON review.id = relation.review_event_id").
			Where("relation.dish_id = ? AND review.status = ?", dishID, models.ReviewEventStatusActive).
			Order("review.created_at DESC, review.id DESC").Find(&relations).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取菜品评价失败"})
			return
		}
		parentIDs := make([]uint, 0, len(relations))
		seenParentIDs := make(map[uint]struct{}, len(relations))
		for _, relation := range relations {
			if _, exists := seenParentIDs[relation.ReviewEventID]; exists {
				continue
			}
			seenParentIDs[relation.ReviewEventID] = struct{}{}
			parentIDs = append(parentIDs, relation.ReviewEventID)
		}
		if len(parentIDs) > 0 {
			var parents []models.CanteenReviewEvent
			if err := h.db.Preload("User").Where("id IN ?", parentIDs).Find(&parents).Error; err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "获取菜品评价失败"})
				return
			}
			for _, parent := range parents {
				parentByID[parent.ID] = parent
			}
		}

		var dishReviews []models.CanteenDishReviewEvent
		if len(parentIDs) > 0 && h.db.Migrator().HasTable(&models.CanteenDishReviewEvent{}) {
			if err := h.db.Where("dish_id = ? AND status = ? AND canteen_review_event_id IN ?", dishID, models.ReviewEventStatusActive, parentIDs).
				Preload("User").Find(&dishReviews).Error; err != nil && len(parentIDs) > 0 {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "获取菜品评价失败"})
				return
			}
		}
		childByParent := make(map[uint]models.CanteenDishReviewEvent, len(dishReviews))
		for _, dishReview := range dishReviews {
			if dishReview.CanteenReviewEventID != nil {
				childByParent[*dishReview.CanteenReviewEventID] = dishReview
			}
		}
		for _, relation := range relations {
			parent, exists := parentByID[relation.ReviewEventID]
			if !exists {
				continue
			}
			populateReviewPublicFields(h.db, &parent)
			payload := map[string]interface{}{
				"id":                      parent.ID,
				"review_id":               parent.ID,
				"dish_id":                 uint(dishID),
				"user_id":                 parent.UserID,
				"user_name":               parent.UserName,
				"user_avatar":             parent.UserAvatar,
				"credit_score":            parent.CreditScore,
				"credit_weight":           parent.CreditWeight,
				"history_count":           parent.HistoryCount,
				"taste_score":             parent.TasteScore,
				"value_score":             parent.ValueScore,
				"queue_score":             parent.QueueScore,
				"hygiene_score":           parent.HygieneScore,
				"service_score":           parent.ServiceScore,
				"portion_score":           0,
				"overall_score":           parent.OverallScore,
				"comment":                 parent.Comment,
				"images":                  decodeStringList(parent.Images),
				"tags":                    decodeStringList(parent.Tags),
				"status":                  parent.Status,
				"score_version":           parent.ScoreVersion,
				"canteen_review_event_id": parent.ID,
				"parent_review_event_id":  parent.ID,
				"created_at":              parent.CreatedAt,
				"updated_at":              parent.UpdatedAt,
				"review_source":           "canteen_review_event",
			}
			if child, ok := childByParent[parent.ID]; ok {
				populateDishReviewPublicFields(h.db, &child)
				payload["dish_review_id"] = child.ID
				payload["portion_score"] = child.PortionScore
				payload["dish_taste_score"] = child.TasteScore
				payload["dish_value_score"] = child.ValueScore
				payload["dish_overall_score"] = child.OverallScore
			}
			parentIncluded[parent.ID] = struct{}{}
			items = append(items, responseItem{
				userID: parent.UserID, createdAt: parent.CreatedAt, id: parent.ID, payload: payload,
			})
		}
	}

	// 保留没有主评价关系的历史独立菜品评价，避免升级期间丢失旧数据。
	if h.db.Migrator().HasTable(&models.CanteenDishReviewEvent{}) {
		var legacyEvents []models.CanteenDishReviewEvent
		if err := h.db.Where("dish_id = ? AND status = ?", dishID, models.ReviewEventStatusActive).
			Preload("User").Order("created_at DESC, id DESC").Find(&legacyEvents).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取菜品评价失败"})
			return
		}
		for _, event := range legacyEvents {
			if event.CanteenReviewEventID != nil {
				if _, represented := parentIncluded[*event.CanteenReviewEventID]; represented {
					continue
				}
			}
			populateDishReviewPublicFields(h.db, &event)
			items = append(items, responseItem{
				userID: event.UserID, createdAt: event.CreatedAt, id: event.ID,
				payload: map[string]interface{}{
					"id": event.ID, "dish_review_id": event.ID, "dish_id": event.DishID,
					"user_id": event.UserID, "user_name": event.UserName, "user_avatar": event.UserAvatar,
					"credit_score": event.CreditScore, "credit_weight": event.CreditWeight,
					"taste_score": event.TasteScore, "value_score": event.ValueScore,
					"portion_score": event.PortionScore, "overall_score": event.OverallScore,
					"comment": event.Comment, "status": event.Status, "score_version": event.ScoreVersion,
					"canteen_review_event_id": event.CanteenReviewEventID,
					"parent_review_event_id":  event.CanteenReviewEventID,
					"created_at":              event.CreatedAt, "updated_at": event.UpdatedAt,
					"review_source": "canteen_dish_review",
				},
			})
		}
	}

	sort.SliceStable(items, func(i, j int) bool {
		if items[i].createdAt.Equal(items[j].createdAt) {
			return items[i].id > items[j].id
		}
		return items[i].createdAt.After(items[j].createdAt)
	})
	if c.Query("history") != "1" {
		seenUsers := make(map[uint]struct{}, len(items))
		latest := items[:0]
		for _, item := range items {
			if _, seen := seenUsers[item.userID]; seen {
				continue
			}
			seenUsers[item.userID] = struct{}{}
			latest = append(latest, item)
		}
		items = latest
	}
	response := make([]map[string]interface{}, 0, len(items))
	for _, item := range items {
		response = append(response, item.payload)
	}
	c.JSON(http.StatusOK, gin.H{"items": response, "count": len(response)})
}

var (
	errReviewForbidden          = errors.New("review_forbidden")
	errReviewNotActive          = errors.New("review_not_active")
	errReviewNotLatest          = errors.New("review_not_latest")
	errReviewConflict           = errors.New("review_conflict")
	errReviewDishInvalid        = errors.New("review_dish_invalid")
	errDishReviewEventInvalid   = errors.New("dish_review_event_invalid")
	errDishReviewEventForbidden = errors.New("dish_review_event_forbidden")
	errLegacyRatingSuperseded   = errors.New("legacy_rating_superseded")
)

func authenticatedUserID(c *gin.Context) (uint, bool) {
	value, exists := c.Get("user_id")
	userID, valid := value.(uint)
	if !exists || !valid || userID == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录后操作", "code": "authentication_required"})
		return 0, false
	}
	return userID, true
}

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
			summary.Status = models.ReviewEventStatusActive
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
	summary.Status = models.ReviewEventStatusActive
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
	result := make([]uint, 0, 1)
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

// resolveReviewDishInputs 在一次评价事务内解析菜名和菜品 ID。
// 已有 active 菜直接关联；未收录菜名随评价直接创建 active 菜品。
func (h *CanteenHandler) resolveReviewDishInputs(tx *gorm.DB, canteenID, userID uint, ids []uint, names []string, legacyReviews, dishes []reviewDishInput) ([]reviewDishInput, []uint, error) {
	resolved := make([]reviewDishInput, 0, len(legacyReviews)+len(dishes)+len(names))
	selected := make([]uint, 0, 1)

	appendDish := func(input reviewDishInput) error {
		name := strings.TrimSpace(input.DishName)
		var dish models.CanteenDish
		if input.DishID > 0 {
			if err := tx.Where("id = ? AND canteen_id = ?", input.DishID, canteenID).First(&dish).Error; err != nil {
				return fmt.Errorf("%w: 菜品不存在", errReviewDishInvalid)
			}
			if dish.Status == models.DishStatusHidden || dish.Status == models.DishStatusMerged {
				return fmt.Errorf("%w: 菜品已下架或合并，请刷新后重新选择", errReviewDishConflict)
			}
			if name == "" {
				name = dish.Name
			}
		} else if name != "" {
			var err error
			normalized := utils.NormalizeDishName(name)
			err = tx.Where("canteen_id = ? AND normalized_name = ?", canteenID, normalized).First(&dish).Error
			if err == nil && dish.Status == models.DishStatusMerged {
				var alias models.CanteenDishAlias
				if aliasErr := tx.Where("canteen_id = ? AND normalized_alias = ?", canteenID, normalized).First(&alias).Error; aliasErr == nil {
					if targetErr := tx.Where("id = ? AND canteen_id = ? AND status = ?", alias.DishID, canteenID, models.DishStatusActive).First(&dish).Error; targetErr != nil {
						return fmt.Errorf("%w: 菜品合并目标已变化，请刷新后重新选择", errReviewDishConflict)
					}
				} else {
					return fmt.Errorf("%w: 菜品已合并，请刷新后重新选择", errReviewDishConflict)
				}
			}
			if errors.Is(err, gorm.ErrRecordNotFound) {
				dish = models.CanteenDish{CanteenID: canteenID, Name: name, NormalizedName: normalized, Status: models.DishStatusActive, CreatedBy: userID}
				result := tx.Create(&dish)
				if result.Error != nil && !isUniqueConstraintError(result.Error) {
					return result.Error
				}
				if result.Error != nil || result.RowsAffected == 0 {
					if err := tx.Where("canteen_id = ? AND normalized_name = ?", canteenID, normalized).First(&dish).Error; err != nil {
						return err
					}
				}
			} else if err != nil {
				return err
			}
			if dish.Status == models.DishStatusHidden || dish.Status == models.DishStatusMerged {
				return fmt.Errorf("%w: 同名菜品已下架或合并，请刷新后重新选择", errReviewDishConflict)
			}
		}
		if dish.ID == 0 {
			return nil
		}
		input.DishID, input.DishName = dish.ID, dish.Name
		selected = uniqueReviewDishIDs(selected, []uint{dish.ID})
		resolved = append(resolved, input)
		return nil
	}

	for _, id := range ids {
		if id == 0 {
			continue
		}
		if err := appendDish(reviewDishInput{DishID: id}); err != nil {
			return nil, nil, err
		}
	}
	for _, input := range legacyReviews {
		if input.DishID == 0 && strings.TrimSpace(input.DishName) == "" {
			continue
		}
		if err := appendDish(input); err != nil {
			return nil, nil, err
		}
	}
	for _, input := range dishes {
		if input.DishID == 0 && strings.TrimSpace(input.DishName) == "" {
			continue
		}
		if err := appendDish(input); err != nil {
			return nil, nil, err
		}
	}
	for _, name := range names {
		if err := appendDish(reviewDishInput{DishName: name}); err != nil {
			return nil, nil, err
		}
	}
	if len(selected) > 1 {
		return nil, nil, fmt.Errorf("%w: 每条评价只能选择1道菜品", errReviewDishInvalid)
	}
	return dedupeReviewDishInputs(resolved), selected, nil
}

func dedupeReviewDishInputs(inputs []reviewDishInput) []reviewDishInput {
	byDish := make(map[uint]reviewDishInput, len(inputs))
	order := make([]uint, 0, len(inputs))
	for _, input := range inputs {
		if input.DishID == 0 {
			continue
		}
		if _, exists := byDish[input.DishID]; !exists {
			order = append(order, input.DishID)
		}
		current := byDish[input.DishID]
		current.DishID = input.DishID
		if input.TasteScore != 0 || input.ValueScore != 0 || input.PortionScore != 0 || input.Comment != "" {
			current.TasteScore, current.ValueScore, current.PortionScore, current.Comment = input.TasteScore, input.ValueScore, input.PortionScore, input.Comment
		}
		if len(input.PhotoFileIDs) > 0 {
			current.PhotoFileIDs = append(current.PhotoFileIDs, input.PhotoFileIDs...)
		}
		if current.DishName == "" {
			current.DishName = input.DishName
		}
		byDish[input.DishID] = current
	}
	result := make([]reviewDishInput, 0, len(order))
	for _, id := range order {
		input := byDish[id]
		seen := map[uint]struct{}{}
		files := input.PhotoFileIDs[:0]
		for _, fileID := range input.PhotoFileIDs {
			if fileID == 0 {
				continue
			}
			if _, exists := seen[fileID]; exists {
				continue
			}
			seen[fileID] = struct{}{}
			files = append(files, fileID)
		}
		input.PhotoFileIDs = files
		result = append(result, input)
	}
	return result
}

// syncDishReviews 同步一条到店评价的菜品关联关系。
func (h *CanteenHandler) syncDishReviews(tx *gorm.DB, canteenID, userID, reviewEventID uint, selectedIDs []uint, inputs []reviewDishInput) error {
	selected := make(map[uint]struct{}, len(selectedIDs))
	for _, id := range selectedIDs {
		var dish models.CanteenDish
		if err := tx.Where("id = ? AND canteen_id = ? AND status IN ?", id, canteenID, []string{
			models.DishStatusActive, models.DishStatusPending, models.DishStatusRejected, models.DishStatusArchived,
		}).First(&dish).Error; err != nil {
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
			return fmt.Errorf("%w: 菜品必须属于已选择的菜品", errReviewDishInvalid)
		}
		allEmpty := input.TasteScore == 0 && input.ValueScore == 0 && input.PortionScore == 0
		if allEmpty {
			continue
		}
		if !services.ValidateDishScores(services.DishScores{Taste: input.TasteScore, Value: input.ValueScore, Portion: input.PortionScore}) {
			return fmt.Errorf("%w: 菜品评分需完整填写1到5分，或全部留空", errReviewDishInvalid)
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

// syncDishPhotos 将评价编辑器中上传的关联菜品图片直接保存为 approved，
// 并自动将对应 File 设为 public。
func (h *CanteenHandler) syncDishPhotos(tx *gorm.DB, userID, reviewEventID uint, inputs []reviewDishInput) error {
	wanted := make(map[string]reviewDishInput)
	allFileIDs := make([]uint, 0)
	for _, input := range inputs {
		if len(input.PhotoFileIDs) > 3 {
			return fmt.Errorf("%w: 每道菜最多提交3张实拍", errReviewDishInvalid)
		}
		for _, fileID := range input.PhotoFileIDs {
			if fileID == 0 {
				continue
			}
			key := fmt.Sprintf("%d:%d", input.DishID, fileID)
			wanted[key] = input
			allFileIDs = append(allFileIDs, fileID)
		}
	}
	if len(allFileIDs) > 0 {
		if _, err := services.ValidateImageFileIDs(tx, allFileIDs, len(allFileIDs), userID); err != nil {
			return err
		}
	}

	var existing []models.CanteenDishPhoto
	if err := tx.Where("review_event_id = ?", reviewEventID).Find(&existing).Error; err != nil {
		return err
	}
	seenExisting := make(map[string]struct{}, len(existing))
	for _, photo := range existing {
		key := fmt.Sprintf("%d:%d", photo.DishID, photo.FileID)
		if _, keep := wanted[key]; keep {
			seenExisting[key] = struct{}{}
			continue
		}
		// 历史关联移除：解除 review_event_id 绑定，保留 approved 社区实拍
		if err := tx.Model(&models.CanteenDishPhoto{}).Where("id = ?", photo.ID).Update("review_event_id", nil).Error; err != nil {
			return err
		}
	}

	newFileIDs := make([]uint, 0)
	for key, input := range wanted {
		if _, exists := seenExisting[key]; exists {
			continue
		}
		var duplicate models.CanteenDishPhoto
		err := tx.Where("file_id = ?", strings.Split(key, ":")[1]).First(&duplicate).Error
		if err == nil {
			if duplicate.ReviewEventID != nil && *duplicate.ReviewEventID == reviewEventID {
				continue
			}
			return fmt.Errorf("%w: 图片已绑定到其他菜品", errReviewDishInvalid)
		}
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		fileID := uint(0)
		_, _ = fmt.Sscanf(strings.Split(key, ":")[1], "%d", &fileID)
		if fileID == 0 || input.DishID == 0 {
			continue
		}
		photo := models.CanteenDishPhoto{
			DishID: input.DishID, FileID: fileID, UserID: userID,
			Status: models.DishPhotoStatusApproved, ReviewEventID: &reviewEventID,
		}
		if err := tx.Create(&photo).Error; err != nil {
			return err
		}
		newFileIDs = append(newFileIDs, fileID)
	}

	if len(newFileIDs) > 0 {
		if err := services.ClaimPublicImageFiles(tx, newFileIDs); err != nil {
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
