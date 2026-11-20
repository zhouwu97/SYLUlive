package services

import (
	"context"
	"errors"
	"math"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

// FeedVisibilityService 负责 Feed 显式负反馈的读写与统一查询过滤。
//
// 语义（FEED-1，2026-11-13 调整）：
//   - 不看TA（UserHiddenAuthor）：对 综合/最新/精华/关注/热门 全部生效；
//   - 不感兴趣（FeedFeedback, not_interested）：同样对首页全部信息流 Tab 生效，
//     用户标记后在首页任何 Tab 都不再看到这条帖子；同时作为降权信号，
//     降低同作者、同版块帖子在推荐流中的排序（见 NegativeProfile）。
//   - 搜索、帖子详情、作者主页、版块内页不经过这里，仍然可以找到被标记的帖子。
//
// 过滤 SQL 只允许在这里出现一次，禁止复制到多个 Handler。
type FeedVisibilityService struct {
	db *gorm.DB
}

func NewFeedVisibilityService(db *gorm.DB) *FeedVisibilityService {
	return &FeedVisibilityService{db: db}
}

// GetHiddenAuthorIDs 返回用户隐藏的作者 ID 列表（按隐藏时间倒序）。
func (s *FeedVisibilityService) GetHiddenAuthorIDs(userID uint) ([]uint, error) {
	if userID == 0 {
		return []uint{}, nil
	}
	var ids []uint
	err := s.db.Model(&models.UserHiddenAuthor{}).
		Where("user_id = ?", userID).
		Order("created_at DESC").
		Pluck("author_id", &ids).Error
	return ids, err
}

// GetNotInterestedPostIDs 返回用户标记不感兴趣的帖子 ID 列表（按时间倒序）。
// H1.4：只返回未过期的反馈（expires_at IS NULL 视为仍有效，兼容历史数据）。
func (s *FeedVisibilityService) GetNotInterestedPostIDs(userID uint, now time.Time) ([]uint, error) {
	if userID == 0 {
		return []uint{}, nil
	}
	var ids []uint
	err := s.db.Model(&models.FeedFeedback{}).
		Where("user_id = ? AND action = ? AND (expires_at IS NULL OR expires_at > ?)", userID, models.FeedFeedbackActionNotInterested, now).
		Order("created_at DESC").
		Pluck("post_id", &ids).Error
	return ids, err
}

// HideAuthor 隐藏作者（幂等：已存在则忽略）。
func (s *FeedVisibilityService) HideAuthor(userID, authorID uint) error {
	if userID == 0 || authorID == 0 {
		return errors.New("user_id 和 author_id 不能为 0")
	}
	return s.db.Clauses(clause.OnConflict{DoNothing: true}).Create(&models.UserHiddenAuthor{
		UserID:   userID,
		AuthorID: authorID,
	}).Error
}

// RestoreAuthor 恢复显示作者（不存在则忽略）。
func (s *FeedVisibilityService) RestoreAuthor(userID, authorID uint) error {
	if userID == 0 || authorID == 0 {
		return errors.New("user_id 和 author_id 不能为 0")
	}
	return s.db.Where("user_id = ? AND author_id = ?", userID, authorID).
		Delete(&models.UserHiddenAuthor{}).Error
}

// MarkNotInterested 标记不感兴趣。
//
// H1.4：有效期 90 天。重复标记视为重新表达负反馈，用 upsert 刷新
// Source / CreatedAt / ExpiresAt，避免 90 天有效期由首次点击时间永久决定。
func (s *FeedVisibilityService) MarkNotInterested(userID, postID uint, source string) error {
	if userID == 0 || postID == 0 {
		return errors.New("user_id 和 post_id 不能为 0")
	}
	if !models.IsValidFeedFeedbackSource(source) {
		return errors.New("无效的 source")
	}
	now := time.Now()
	expiresAt := now.Add(90 * 24 * time.Hour)
	return s.db.Clauses(clause.OnConflict{
		Columns: []clause.Column{{Name: "user_id"}, {Name: "post_id"}, {Name: "action"}},
		DoUpdates: clause.Assignments(map[string]interface{}{
			"source":     source,
			"created_at": now,
			"expires_at": expiresAt,
		}),
	}).Create(&models.FeedFeedback{
		UserID:    userID,
		PostID:    postID,
		Action:    models.FeedFeedbackActionNotInterested,
		Source:    source,
		CreatedAt: now,
		ExpiresAt: &expiresAt,
	}).Error
}

// UndoNotInterested 撤销不感兴趣（不存在则忽略）。
func (s *FeedVisibilityService) UndoNotInterested(userID, postID uint) error {
	if userID == 0 || postID == 0 {
		return errors.New("user_id 和 post_id 不能为 0")
	}
	return s.db.Where("user_id = ? AND post_id = ? AND action = ?",
		userID, postID, models.FeedFeedbackActionNotInterested).
		Delete(&models.FeedFeedback{}).Error
}

// ApplyFeedVisibility 将负反馈过滤作用到 Feed 查询上。
//
// feedKind 为首页 Feed Tab（all / time / featured / following / hot），两类过滤对所有 Tab 一致：
//   - hidden author：NOT EXISTS user_hidden_authors；
//   - not_interested：NOT EXISTS feed_feedbacks，且未过期。
//
// 只能在首页信息流里调用；搜索请求不能经过这里，否则「搜索仍能看到」的约定会被破坏。
// userID == 0（未登录）时原样返回。
func (s *FeedVisibilityService) ApplyFeedVisibility(query *gorm.DB, userID uint, feedKind string, now time.Time) *gorm.DB {
	if query == nil || userID == 0 {
		return query
	}
	_ = feedKind
	query = query.Where(
		"NOT EXISTS (SELECT 1 FROM user_hidden_authors uha WHERE uha.user_id = ? AND uha.author_id = posts.author_id)",
		userID,
	)
	return query.Where(
		"NOT EXISTS (SELECT 1 FROM feed_feedbacks ff WHERE ff.user_id = ? AND ff.post_id = posts.id AND ff.action = ? AND (ff.expires_at IS NULL OR ff.expires_at > ?))",
		userID, models.FeedFeedbackActionNotInterested, now,
	)
}

// FeedNegativeProfile 由用户未过期的「不感兴趣」反馈汇总出的降权画像。
// 权重按天衰减（0.98^天），90 天有效期内越早的反馈影响越小。
type FeedNegativeProfile struct {
	AuthorWeight  map[uint]float64
	SectionWeight map[string]float64
}

const (
	// notInterestedDecayPerDay 比互动信号（0.95）衰减慢：负反馈是用户明确表达，应持续得更久。
	notInterestedDecayPerDay = 0.98
	// 同作者第一次标记约降 22%，多次后趋近 35%；同版块需要多次标记才明显（上限 15%）。
	feedbackAuthorPenaltyMax  = 0.35
	feedbackSectionPenaltyMax = 0.15
	// MaxFeedbackPenalty 总降权上限：只压低排序，不把作者或版块从推荐流里整体抹掉。
	MaxFeedbackPenalty = 0.45
	// 只读取最近的反馈，避免极少数重度用户拖慢快照构建。
	negativeProfileLimit = 300
)

// Empty 表示没有任何可用的负反馈信号。
func (p FeedNegativeProfile) Empty() bool {
	return len(p.AuthorWeight) == 0 && len(p.SectionWeight) == 0
}

// Penalty 返回候选帖子的降权比例（0 ~ MaxFeedbackPenalty）。
func (p FeedNegativeProfile) Penalty(authorID uint, section string) float64 {
	penalty := saturation(p.AuthorWeight[authorID], 1) * feedbackAuthorPenaltyMax
	if section != "" {
		penalty += saturation(p.SectionWeight[section], 3) * feedbackSectionPenaltyMax
	}
	return math.Min(MaxFeedbackPenalty, penalty)
}

// NegativeProfile 读取用户未过期的「不感兴趣」反馈，按帖子作者和版块聚合权重。
// 读取失败时返回错误，由调用方决定是否忽略（降权是增强项，不能阻断首页）。
func (s *FeedVisibilityService) NegativeProfile(ctx context.Context, userID uint, now time.Time) (FeedNegativeProfile, error) {
	profile := FeedNegativeProfile{AuthorWeight: map[uint]float64{}, SectionWeight: map[string]float64{}}
	if userID == 0 {
		return profile, nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	var rows []struct {
		AuthorID  uint
		PostType  string
		CreatedAt time.Time
	}
	err := s.db.WithContext(ctx).
		Table("feed_feedbacks ff").
		Select("p.author_id AS author_id, p.post_type AS post_type, ff.created_at AS created_at").
		Joins("JOIN posts p ON p.id = ff.post_id").
		Where("ff.user_id = ? AND ff.action = ? AND (ff.expires_at IS NULL OR ff.expires_at > ?)", userID, models.FeedFeedbackActionNotInterested, now).
		Order("ff.created_at DESC").
		Limit(negativeProfileLimit).
		Scan(&rows).Error
	if err != nil {
		return profile, err
	}
	for _, row := range rows {
		days := math.Max(now.Sub(row.CreatedAt).Hours()/24, 0)
		weight := math.Pow(notInterestedDecayPerDay, days)
		if row.AuthorID > 0 {
			profile.AuthorWeight[row.AuthorID] += weight
		}
		if row.PostType != "" {
			profile.SectionWeight[row.PostType] += weight
		}
	}
	return profile, nil
}

// CleanupExpiredFeedbacks 清理已过期的 not_interested 反馈（expires_at 已到）。
// 历史 NULL 记录视为永久有效，不会被清理。返回删除条数。
func (s *FeedVisibilityService) CleanupExpiredFeedbacks(ctx context.Context, now time.Time) (int64, error) {
	res := s.db.WithContext(ctx).
		Where("action = ? AND expires_at IS NOT NULL AND expires_at <= ?", models.FeedFeedbackActionNotInterested, now).
		Delete(&models.FeedFeedback{})
	return res.RowsAffected, res.Error
}
