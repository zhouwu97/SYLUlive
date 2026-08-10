package services

import (
	"errors"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

// FeedVisibilityService 负责 Feed 显式负反馈的读写与统一查询过滤。
//
// 语义（FEED-1）：
//   - 不看TA（UserHiddenAuthor）：对 综合/最新/精华/关注 全部生效；
//   - 不感兴趣（FeedFeedback, not_interested）：第一版只对 综合（all）生效，
//     「最新 / 关注」属于用户主动查看路径，不偷偷过滤。
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
func (s *FeedVisibilityService) GetNotInterestedPostIDs(userID uint) ([]uint, error) {
	if userID == 0 {
		return []uint{}, nil
	}
	var ids []uint
	err := s.db.Model(&models.FeedFeedback{}).
		Where("user_id = ? AND action = ?", userID, models.FeedFeedbackActionNotInterested).
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

// MarkNotInterested 标记不感兴趣（幂等：已存在则忽略）。
func (s *FeedVisibilityService) MarkNotInterested(userID, postID uint, source string) error {
	if userID == 0 || postID == 0 {
		return errors.New("user_id 和 post_id 不能为 0")
	}
	if !models.IsValidFeedFeedbackSource(source) {
		return errors.New("无效的 source")
	}
	return s.db.Clauses(clause.OnConflict{DoNothing: true}).Create(&models.FeedFeedback{
		UserID: userID,
		PostID: postID,
		Action: models.FeedFeedbackActionNotInterested,
		Source: source,
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
// feedKind 为 Feed Tab：all / time / featured / following。
//   - hidden author：所有 Tab 生效（NOT EXISTS user_hidden_authors）；
//   - not_interested：仅 all 生效（NOT EXISTS feed_feedbacks）。
//
// userID == 0（未登录）时原样返回。
func (s *FeedVisibilityService) ApplyFeedVisibility(query *gorm.DB, userID uint, feedKind string) *gorm.DB {
	if query == nil || userID == 0 {
		return query
	}
	query = query.Where(
		"NOT EXISTS (SELECT 1 FROM user_hidden_authors uha WHERE uha.user_id = ? AND uha.author_id = posts.author_id)",
		userID,
	)
	if feedKind == "all" {
		query = query.Where(
			"NOT EXISTS (SELECT 1 FROM feed_feedbacks ff WHERE ff.user_id = ? AND ff.post_id = posts.id AND ff.action = ?)",
			userID, models.FeedFeedbackActionNotInterested,
		)
	}
	return query
}
