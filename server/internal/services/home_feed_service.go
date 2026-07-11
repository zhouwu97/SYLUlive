package services

import (
	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"time"
)

type HomeFeedService struct{ db *gorm.DB }

func NewHomeFeedService(db *gorm.DB) *HomeFeedService { return &HomeFeedService{db: db} }

func (s *HomeFeedService) PinnedPosts(now time.Time) ([]models.Post, error) {
	var posts []models.Post
	err := s.db.Where("board_id = ? AND status != ? AND is_pinned = ? AND (pinned_until IS NULL OR pinned_until > ?)", models.BoardShuitie, models.PostStatusDeleted, true, now).Order("pinned_weight DESC").Order("pinned_at DESC").Order("id DESC").Limit(3).Find(&posts).Error
	return posts, err
}
func (s *HomeFeedService) BuildSnapshot(now time.Time) ([]uint, error) {
	base := func() *gorm.DB {
		return s.db.Model(&models.Post{}).Where("board_id = ? AND status = ?", models.BoardShuitie, models.PostStatusNormal).Where("NOT EXISTS (SELECT 1 FROM water_team_recruitments wtr WHERE wtr.post_id = posts.id)").Where("NOT (is_pinned = ? AND (pinned_until IS NULL OR pinned_until > ?))", true, now)
	}
	var posts []models.Post
	appendPool := func(q *gorm.DB) error {
		var pool []models.Post
		if err := q.Find(&pool).Error; err != nil {
			return err
		}
		posts = append(posts, pool...)
		return nil
	}
	if err := appendPool(base().Where("created_at >= ?", now.Add(-30*24*time.Hour)).Order("created_at DESC").Limit(300)); err != nil {
		return nil, err
	}
	if err := appendPool(base().Where("last_activity_at >= ? AND created_at >= ? AND reply_count > 0", now.Add(-72*time.Hour), now.Add(-180*24*time.Hour)).Order("last_activity_at DESC").Limit(100)); err != nil {
		return nil, err
	}
	if err := appendPool(base().Where("is_featured = ? AND created_at >= ?", true, now.Add(-180*24*time.Hour)).Order("created_at DESC").Limit(100)); err != nil {
		return nil, err
	}
	seen := map[uint]bool{}
	unique := make([]models.Post, 0, len(posts))
	for _, p := range posts {
		if !seen[p.ID] {
			seen[p.ID] = true
			unique = append(unique, p)
		}
	}
	if len(unique) < 100 {
		var more []models.Post
		if err := base().Order("created_at DESC").Limit(500).Find(&more).Error; err != nil {
			return nil, err
		}
		for _, p := range more {
			if !seen[p.ID] {
				seen[p.ID] = true
				unique = append(unique, p)
			}
		}
	}
	if len(unique) == 0 {
		return []uint{}, nil
	}
	ids := make([]uint, len(unique))
	for i, p := range unique {
		ids[i] = p.ID
	}
	var rows []struct {
		PostID uint
		Count  int64
	}
	if err := s.db.Model(&models.Reply{}).Select("post_id, COUNT(DISTINCT author_id) as count").Where("status = ? AND post_id IN ?", models.ReplyStatusNormal, ids).Group("post_id").Scan(&rows).Error; err != nil {
		return nil, err
	}
	counts := map[uint]int64{}
	for _, row := range rows {
		counts[row.PostID] = row.Count
	}
	candidates := make([]HomeFeedCandidate, 0, len(unique))
	for _, p := range unique {
		candidates = append(candidates, HomeFeedCandidate{Post: p, UniqueReplierCount: counts[p.ID]})
	}
	ranked := RankHomeFeed(candidates, now)
	if len(ranked) > 500 {
		ranked = ranked[:500]
	}
	return ranked, nil
}
