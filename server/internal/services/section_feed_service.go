package services

import (
	"time"

	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// SectionFeedService 构建单个水帖版块的推荐快照。
type SectionFeedService struct {
	db          *gorm.DB
	includePoll bool
}

func NewSectionFeedService(db *gorm.DB, includePoll bool) *SectionFeedService {
	return &SectionFeedService{db: db, includePoll: includePoll}
}

// BuildSnapshot 返回指定版块的稳定帖子 ID 顺序，供 refresh/loadmore 共用。
func (s *SectionFeedService) BuildSnapshot(sectionID uint, sectionSlug string, now time.Time) ([]uint, error) {
	base := func() *gorm.DB {
		query := s.db.Model(&models.Post{}).
			Where("board_id = ? AND status != ?", models.BoardShuitie, models.PostStatusDeleted).
			Where("NOT EXISTS (SELECT 1 FROM water_team_recruitments wtr WHERE wtr.post_id = posts.id)")
		if !s.includePoll {
			query = query.Where("content_kind <> ?", models.PostContentKindPoll)
		}
		if sectionSlug == "campus_life" {
			return query.Where("(post_type = ? OR post_type IS NULL OR post_type = '')", sectionSlug)
		}
		return query.Where("post_type = ?", sectionSlug)
	}

	var featuredRows []models.WaterSectionFeaturedPost
	if err := s.db.Where("section_id = ? AND status = ?", sectionID, models.SectionFeaturedStatusActive).Find(&featuredRows).Error; err != nil {
		return nil, err
	}
	featuredAt := make(map[uint]time.Time, len(featuredRows))
	featuredIDs := make([]uint, 0, len(featuredRows))
	for _, row := range featuredRows {
		featuredIDs = append(featuredIDs, row.PostID)
		if previous, ok := featuredAt[row.PostID]; !ok || row.CreatedAt.After(previous) {
			featuredAt[row.PostID] = row.CreatedAt
		}
	}

	var pinRows []models.WaterSectionPin
	if err := s.db.Where("section_id = ? AND status = ? AND (pinned_until IS NULL OR pinned_until > ?)", sectionID, models.PinStatusActive, now).Find(&pinRows).Error; err != nil {
		return nil, err
	}
	pinnedWeights := make(map[uint]int, len(pinRows))
	pinnedIDs := make([]uint, 0, len(pinRows))
	for _, row := range pinRows {
		pinnedIDs = append(pinnedIDs, row.PostID)
		if previous, ok := pinnedWeights[row.PostID]; !ok || row.Weight > previous {
			pinnedWeights[row.PostID] = row.Weight
		}
	}

	var posts []models.Post
	appendPool := func(query *gorm.DB) error {
		var pool []models.Post
		if err := query.Order("posts.created_at DESC").Find(&pool).Error; err != nil {
			return err
		}
		posts = append(posts, pool...)
		return nil
	}
	if err := appendPool(base().Where("created_at >= ?", now.Add(-30*24*time.Hour)).Limit(300)); err != nil {
		return nil, err
	}
	if err := appendPool(base().Where("last_activity_at >= ? AND created_at >= ? AND reply_count > 0", now.Add(-72*time.Hour), now.Add(-180*24*time.Hour)).Limit(100)); err != nil {
		return nil, err
	}
	if len(featuredIDs) > 0 {
		if err := appendPool(base().Where("id IN ?", featuredIDs).Limit(200)); err != nil {
			return nil, err
		}
	}
	if len(pinnedIDs) > 0 {
		if err := appendPool(base().Where("id IN ?", pinnedIDs).Limit(200)); err != nil {
			return nil, err
		}
	}

	seen := make(map[uint]bool, len(posts))
	unique := make([]models.Post, 0, len(posts))
	for _, post := range posts {
		if !seen[post.ID] {
			seen[post.ID] = true
			unique = append(unique, post)
		}
	}
	if len(unique) < 100 {
		if err := appendPool(base().Limit(500)); err != nil {
			return nil, err
		}
		for _, post := range posts {
			if !seen[post.ID] {
				seen[post.ID] = true
				unique = append(unique, post)
			}
		}
	}
	if len(unique) == 0 {
		return []uint{}, nil
	}

	ids := make([]uint, 0, len(unique))
	for _, post := range unique {
		ids = append(ids, post.ID)
	}
	var replyRows []struct {
		PostID uint
		Count  int64
	}
	if err := s.db.Model(&models.Reply{}).
		Select("post_id, COUNT(DISTINCT author_id) AS count").
		Where("status = ? AND post_id IN ?", models.ReplyStatusNormal, ids).
		Group("post_id").Scan(&replyRows).Error; err != nil {
		return nil, err
	}
	uniqueRepliers := make(map[uint]int64, len(replyRows))
	for _, row := range replyRows {
		uniqueRepliers[row.PostID] = row.Count
	}

	pollByPost := make(map[uint]models.Poll)
	if s.includePoll {
		var polls []models.Poll
		if err := s.db.Where("post_id IN ?", ids).Find(&polls).Error; err != nil {
			return nil, err
		}
		for _, poll := range polls {
			pollByPost[poll.PostID] = poll
		}
	}

	candidates := make([]HomeFeedCandidate, 0, len(unique))
	for _, post := range unique {
		if featuredAtValue, ok := featuredAt[post.ID]; ok {
			post.IsFeatured = true
			featuredAtCopy := featuredAtValue
			post.FeaturedAt = &featuredAtCopy
		}
		candidate := HomeFeedCandidate{Post: post, UniqueReplierCount: uniqueRepliers[post.ID]}
		if poll, ok := pollByPost[post.ID]; ok {
			candidate.IsPoll = true
			candidate.PollLastVoteAt = poll.LastVoteAt
			candidate.ParticipantCount = poll.ParticipantCount
			candidate.PollEnded = poll.Status != models.PollStatusActive || !now.Before(poll.EndsAt)
		}
		candidates = append(candidates, candidate)
	}

	ranked := RankSectionFeed(candidates, now, pinnedWeights)
	if len(ranked) > 500 {
		return ranked[:500], nil
	}
	return ranked, nil
}
