package services

import (
	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"time"
)

type HomeFeedService struct {
	db          *gorm.DB
	includePoll bool
	visibility  *FeedVisibilityService
}

func NewHomeFeedService(db *gorm.DB) *HomeFeedService {
	return &HomeFeedService{db: db, visibility: NewFeedVisibilityService(db)}
}

func NewHomeFeedServiceWithPoll(db *gorm.DB) *HomeFeedService {
	return &HomeFeedService{db: db, includePoll: true, visibility: NewFeedVisibilityService(db)}
}

func (s *HomeFeedService) PinnedPosts(now time.Time) ([]models.Post, error) {
	var posts []models.Post
	query := s.db.Where("board_id = ? AND status != ? AND is_pinned = ? AND (pinned_until IS NULL OR pinned_until > ?)", models.BoardShuitie, models.PostStatusDeleted, true, now)
	if !s.includePoll {
		query = query.Where("content_kind <> ?", models.PostContentKindPoll)
	}
	err := query.Order("pinned_weight DESC").Order("pinned_at DESC").Order("id DESC").Limit(3).Find(&posts).Error
	return posts, err
}

// BuildSnapshot 构建首页推荐快照。
// userID > 0 时应用 Feed 负反馈过滤（不看TA 对所有 Tab 生效，不感兴趣仅 all 生效）。
func (s *HomeFeedService) BuildSnapshot(now time.Time, userID uint) ([]uint, error) {
	base := func() *gorm.DB {
		query := s.db.Model(&models.Post{}).Where("board_id = ? AND status = ?", models.BoardShuitie, models.PostStatusNormal).Where("NOT EXISTS (SELECT 1 FROM water_team_recruitments wtr WHERE wtr.post_id = posts.id)").Where("NOT (is_pinned = ? AND (pinned_until IS NULL OR pinned_until > ?))", true, now)
		if !s.includePoll {
			query = query.Where("content_kind <> ?", models.PostContentKindPoll)
		}
		query = s.visibility.ApplyFeedVisibility(query, userID, "all")
		return query
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
	pollByPost := map[uint]models.Poll{}
	if s.includePoll {
		var polls []models.Poll
		if err := s.db.Where("post_id IN ?", ids).Find(&polls).Error; err != nil {
			return nil, err
		}
		for _, poll := range polls {
			pollByPost[poll.PostID] = poll
		}
	}
	for _, p := range unique {
		candidate := HomeFeedCandidate{Post: p, UniqueReplierCount: counts[p.ID]}
		if poll, ok := pollByPost[p.ID]; ok {
			candidate.IsPoll = true
			candidate.PollLastVoteAt = poll.LastVoteAt
			candidate.ParticipantCount = poll.ParticipantCount
			candidate.PollEnded = poll.Status != models.PollStatusActive || !now.Before(poll.EndsAt)
		}
		candidates = append(candidates, candidate)
	}
	ranked := RankHomeFeed(candidates, now)
	if s.includePoll {
		ranked = applyPollDensity(ranked, pollByPost)
	}
	if len(ranked) > 500 {
		ranked = ranked[:500]
	}
	return ranked, nil
}

// applyPollDensity 保持推荐流可扫描性；内容不足时会在末尾保留一个投票入口。
func applyPollDensity(ids []uint, pollByPost map[uint]models.Poll) []uint {
	if len(ids) < 6 {
		return ids
	}
	result := make([]uint, 0, len(ids))
	deferred := make([]uint, 0)
	normalSincePoll := 5
	for _, id := range ids {
		if _, isPoll := pollByPost[id]; isPoll {
			if normalSincePoll >= 5 {
				result = append(result, id)
				normalSincePoll = 0
			} else {
				deferred = append(deferred, id)
			}
			continue
		}
		result = append(result, id)
		normalSincePoll++
		if normalSincePoll >= 5 && len(deferred) > 0 {
			result = append(result, deferred[0])
			deferred = deferred[1:]
			normalSincePoll = 0
		}
	}
	return append(result, deferred...)
}
