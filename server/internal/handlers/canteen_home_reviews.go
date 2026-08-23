package handlers

import (
	"sort"
	"time"

	"shenliyuan/internal/models"
)

// canteenHomeReview 是首页“同学最近在吃”卡片的稳定响应契约。
// source=legacy 时只提供旧评价确实拥有的综合分和文本，不补造五维数据。
type canteenHomeReview struct {
	Source            string             `json:"source"`
	ReviewID          uint               `json:"review_id"`
	CanteenID         uint               `json:"canteen_id"`
	CanteenName       string             `json:"canteen_name"`
	UserID            uint               `json:"user_id"`
	UserName          string             `json:"user_name"`
	UserAvatar        string             `json:"user_avatar,omitempty"`
	CreditScore       int                `json:"credit_score,omitempty"`
	OverallScore      float64            `json:"overall_score"`
	DimensionScores   map[string]float64 `json:"dimension_scores,omitempty"`
	Comment           string             `json:"comment,omitempty"`
	RecommendedDishes []string           `json:"recommended_dishes,omitempty"`
	HistoryCount      int                `json:"history_count,omitempty"`
	CreatedAt         time.Time          `json:"created_at"`
}

type canteenHomeReviewPair struct {
	UserID    uint
	CanteenID uint
}

// loadRecentHomeReviews 读取最新候选评价，并用可信度优先、时间新鲜度次之的顺序展示。
// 一次只给客户端少量候选，最终首页只展示其中一张，避免首页重新变成评价流。
func (h *CanteenHandler) loadRecentHomeReviews(limit int) []canteenHomeReview {
	if limit <= 0 {
		limit = 5
	}
	if limit > 5 {
		limit = 5
	}

	candidates := make([]canteenHomeReview, 0, limit*2)
	hasReviewEvents := h.db.Migrator().HasTable(&models.CanteenReviewEvent{})
	if hasReviewEvents {
		var events []models.CanteenReviewEvent
		err := h.db.Model(&models.CanteenReviewEvent{}).
			Joins("JOIN canteens c ON c.id = canteen_review_events.canteen_id").
			Where("canteen_review_events.status = ?", models.ReviewEventStatusActive).
			Where("(canteen_review_events.score_version >= ? OR canteen_review_events.score_version = ?)", 2, 0).
			Where("c.verified = ? AND (c.operating_status = ? OR c.operating_status IS NULL OR c.operating_status = '')", true, models.CanteenOperatingActive).
			Order("canteen_review_events.created_at DESC, canteen_review_events.id DESC").
			Limit(limit * 3).
			Preload("User").
			Find(&events).Error
		if err == nil {
			h.populateReviewPublicFields(events)
			populateReviewDishNames(h.db, events)
			canteenNames := h.homeCanteenNames(reviewEventCanteenIDs(events))
			for _, event := range events {
				candidates = append(candidates, canteenHomeReview{
					Source:            "v2",
					ReviewID:          event.ID,
					CanteenID:         event.CanteenID,
					CanteenName:       canteenNames[event.CanteenID],
					UserID:            event.UserID,
					UserName:          event.UserName,
					UserAvatar:        event.UserAvatar,
					CreditScore:       event.CreditScore,
					OverallScore:      event.OverallScore,
					DimensionScores:   homeReviewDimensionScores(event),
					Comment:           event.Comment,
					RecommendedDishes: append([]string(nil), event.RecommendedDishNames...),
					HistoryCount:      event.HistoryCount,
					CreatedAt:         event.CreatedAt,
				})
			}
		}
	}

	// 旧评价只在没有对应 V2 到店评价时补充，避免同一用户-食堂样本重复出现。
	var ratings []models.CanteenRating
	ratingQuery := h.db.Model(&models.CanteenRating{}).
		Joins("JOIN canteens c ON c.id = canteen_ratings.canteen_id").
		Where("(canteen_ratings.status = ? OR canteen_ratings.status IS NULL OR canteen_ratings.status = '')", models.ReviewEventStatusActive).
		Where("(canteen_ratings.score_version IS NULL OR canteen_ratings.score_version < ?)", 2).
		Where("c.verified = ? AND (c.operating_status = ? OR c.operating_status IS NULL OR c.operating_status = '')", true, models.CanteenOperatingActive).
		Order("canteen_ratings.created_at DESC, canteen_ratings.id DESC").
		Limit(limit * 3).
		Preload("User")
	if hasReviewEvents {
		ratingQuery = ratingQuery.Where("NOT EXISTS (SELECT 1 FROM canteen_review_events e WHERE e.canteen_id = canteen_ratings.canteen_id AND e.user_id = canteen_ratings.user_id AND e.status = ? AND (e.score_version >= ? OR e.score_version = ?))", models.ReviewEventStatusActive, 2, 0)
	}
	if err := ratingQuery.Find(&ratings).Error; err == nil {
		canteenNames := h.homeCanteenNames(reviewRatingCanteenIDs(ratings))
		for _, rating := range ratings {
			userName, userAvatar, creditScore := homeRatingUserFields(rating)
			candidates = append(candidates, canteenHomeReview{
				Source:       "legacy",
				ReviewID:     rating.ID,
				CanteenID:    rating.CanteenID,
				CanteenName:  canteenNames[rating.CanteenID],
				UserID:       rating.UserID,
				UserName:     userName,
				UserAvatar:   userAvatar,
				CreditScore:  creditScore,
				OverallScore: legacyRatingScore(rating),
				Comment:      rating.Comment,
				HistoryCount: rating.ReviewEventCount,
				CreatedAt:    rating.CreatedAt,
			})
		}
	}

	sort.SliceStable(candidates, func(i, j int) bool {
		if candidates[i].CreatedAt.Equal(candidates[j].CreatedAt) {
			return candidates[i].ReviewID > candidates[j].ReviewID
		}
		return candidates[i].CreatedAt.After(candidates[j].CreatedAt)
	})
	return selectNonConsecutiveHomeReviews(candidates, limit)
}

func (h *CanteenHandler) populateReviewPublicFields(events []models.CanteenReviewEvent) {
	for i := range events {
		populateReviewPublicFields(h.db, &events[i])
	}
}

func homeReviewDimensionScores(event models.CanteenReviewEvent) map[string]float64 {
	allScores := map[string]float64{
		"taste":   float64(event.TasteScore),
		"value":   float64(event.ValueScore),
		"queue":   float64(event.QueueScore),
		"hygiene": float64(event.HygieneScore),
		"service": float64(event.ServiceScore),
	}
	scores := make(map[string]float64, len(allScores))
	for key, score := range allScores {
		if score > 0 {
			scores[key] = score
		}
	}
	if len(scores) == 0 {
		return nil
	}
	return scores
}

func legacyRatingScore(rating models.CanteenRating) float64 {
	if rating.EffectiveScore > 0 {
		return rating.EffectiveScore
	}
	return float64(rating.Star)
}

func homeRatingUserFields(rating models.CanteenRating) (string, string, int) {
	if rating.User == nil {
		return rating.UserName, rating.UserAvatar, rating.CreditScore
	}
	return rating.User.Nickname, rating.User.Avatar, rating.User.CreditScore
}

func reviewEventCanteenIDs(events []models.CanteenReviewEvent) []uint {
	ids := make([]uint, 0, len(events))
	for _, event := range events {
		ids = append(ids, event.CanteenID)
	}
	return ids
}

func reviewRatingCanteenIDs(ratings []models.CanteenRating) []uint {
	ids := make([]uint, 0, len(ratings))
	for _, rating := range ratings {
		ids = append(ids, rating.CanteenID)
	}
	return ids
}

func (h *CanteenHandler) homeCanteenNames(ids []uint) map[uint]string {
	names := make(map[uint]string)
	if len(ids) == 0 {
		return names
	}
	var canteens []models.Canteen
	if err := h.db.Select("id", "name").Where("id IN ?", ids).Find(&canteens).Error; err != nil {
		return names
	}
	for _, canteen := range canteens {
		names[canteen.ID] = canteen.Name
	}
	return names
}

func selectNonConsecutiveHomeReviews(candidates []canteenHomeReview, limit int) []canteenHomeReview {
	selected := make([]canteenHomeReview, 0, limit)
	deferred := make([]canteenHomeReview, 0)
	for _, candidate := range candidates {
		if len(selected) >= limit {
			break
		}
		if len(selected) > 0 && selected[len(selected)-1].UserID == candidate.UserID {
			deferred = append(deferred, candidate)
			continue
		}
		selected = append(selected, candidate)
	}
	for _, candidate := range deferred {
		if len(selected) >= limit {
			break
		}
		if len(selected) == 0 || selected[len(selected)-1].UserID != candidate.UserID {
			selected = append(selected, candidate)
		}
	}
	return selected
}

// todayEffectiveReviewerCount 按“用户 + 食堂”去重统计上海时区当天的有效样本。
// 它与近 7 天评价事件数是两种不同口径，专供首页今日数字使用。
func (h *CanteenHandler) todayEffectiveReviewerCount() int {
	location, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		location = time.FixedZone("Asia/Shanghai", 8*60*60)
	}
	now := time.Now().In(location)
	start := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, location)
	end := start.AddDate(0, 0, 1)
	pairs := make(map[canteenHomeReviewPair]struct{})
	hasReviewEvents := h.db.Migrator().HasTable(&models.CanteenReviewEvent{})

	if hasReviewEvents {
		type pairRow struct {
			UserID    uint `gorm:"column:user_id"`
			CanteenID uint `gorm:"column:canteen_id"`
		}
		var rows []pairRow
		h.db.Table("canteen_review_events AS e").
			Joins("JOIN canteens c ON c.id = e.canteen_id").
			Select("e.user_id, e.canteen_id").
			Where("e.status = ? AND (e.score_version >= ? OR e.score_version = ?)", models.ReviewEventStatusActive, 2, 0).
			Where("e.created_at >= ? AND e.created_at < ?", start, end).
			Where("c.verified = ? AND (c.operating_status = ? OR c.operating_status IS NULL OR c.operating_status = '')", true, models.CanteenOperatingActive).
			Scan(&rows)
		for _, row := range rows {
			pairs[canteenHomeReviewPair{UserID: row.UserID, CanteenID: row.CanteenID}] = struct{}{}
		}
	}

	type pairRow struct {
		UserID    uint `gorm:"column:user_id"`
		CanteenID uint `gorm:"column:canteen_id"`
	}
	var legacyRows []pairRow
	legacyQuery := h.db.Table("canteen_ratings AS r").
		Joins("JOIN canteens c ON c.id = r.canteen_id").
		Select("r.user_id, r.canteen_id").
		Where("(r.status = ? OR r.status IS NULL OR r.status = '') AND (r.score_version IS NULL OR r.score_version < ?)", models.ReviewEventStatusActive, 2).
		Where("r.created_at >= ? AND r.created_at < ?", start, end).
		Where("c.verified = ? AND (c.operating_status = ? OR c.operating_status IS NULL OR c.operating_status = '')", true, models.CanteenOperatingActive)
	if hasReviewEvents {
		legacyQuery = legacyQuery.Where("NOT EXISTS (SELECT 1 FROM canteen_review_events e WHERE e.canteen_id = r.canteen_id AND e.user_id = r.user_id AND e.status = ? AND (e.score_version >= ? OR e.score_version = ?))", models.ReviewEventStatusActive, 2, 0)
	}
	legacyQuery.Scan(&legacyRows)
	for _, row := range legacyRows {
		pairs[canteenHomeReviewPair{UserID: row.UserID, CanteenID: row.CanteenID}] = struct{}{}
	}
	return len(pairs)
}
