package services

import (
	"context"
	"fmt"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type HomeFeedService struct {
	db          *gorm.DB
	includePoll bool
	visibility  *FeedVisibilityService

	// FEED-5：个性化 shadow 开关与 active rollout 百分比（由 handler 注入）。
	personalizationShadow bool
	rolloutPercent        int
	// FEED-V5：v5 算法（reply_like 信号 + 去 raw view + dwell 衰减）。
	v5Shadow       bool
	v5RolloutPercent int
}

func NewHomeFeedService(db *gorm.DB) *HomeFeedService {
	return &HomeFeedService{db: db, visibility: NewFeedVisibilityService(db)}
}

func NewHomeFeedServiceWithPoll(db *gorm.DB) *HomeFeedService {
	return &HomeFeedService{db: db, includePoll: true, visibility: NewFeedVisibilityService(db)}
}

// SetPersonalization 配置 FEED-5 个性化：shadow 计算+trace（不改排序），percent 为
// active rollout 百分比（0=仅 shadow）。
func (s *HomeFeedService) SetPersonalization(shadow bool, percent int) {
	s.personalizationShadow = shadow
	s.rolloutPercent = percent
}

// SetPersonalizationV5 配置 FEED-V5 个性化：独立于 v4 的 shadow/rollout。
func (s *HomeFeedService) SetPersonalizationV5(shadow bool, percent int) {
	s.v5Shadow = shadow
	s.v5RolloutPercent = percent
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
// FEED-5：shadow 个性化在此串联（UserFeatures → PersonalDelta → 探索 → trace）。
func (s *HomeFeedService) BuildSnapshot(ctx context.Context, now time.Time, userID uint) ([]uint, error) {
	base := func() *gorm.DB {
		query := s.db.Model(&models.Post{}).Where("board_id = ? AND status = ?", models.BoardShuitie, models.PostStatusNormal).Where("NOT EXISTS (SELECT 1 FROM water_team_recruitments wtr WHERE wtr.post_id = posts.id)").Where("NOT (is_pinned = ? AND (pinned_until IS NULL OR pinned_until > ?))", true, now)
		if !s.includePoll {
			query = query.Where("content_kind <> ?", models.PostContentKindPoll)
		}
		query = s.visibility.ApplyFeedVisibility(query, userID, "all", now)
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
	// FEED-5/FEED-V5：任何个性化需求（shadow 或 active rollout）都必须进入计算路径。
	// 修复 rollout 陷阱：此前 shadow=false 但 percent>0 时会在计算前直接返回 baseline，
	// 导致"配了 10% 灰度实际 0% 生效"。
	v4Active := s.personalizationShadow || s.rolloutPercent > 0
	v5Active := s.v5Shadow || s.v5RolloutPercent > 0
	if !v4Active && !v5Active {
		return ranked, nil
	}
	baseline := ranked
	features := s.BuildUserFeatures(ctx, userID, ids, now)

	personalized := ranked
	if v4Active {
		for i := range candidates {
			candidates[i].PersonalDelta = ComputePersonalDelta(candidates[i], features, now)
		}
		personalized = RankHomeFeed(candidates, now)
		if s.includePoll {
			personalized = applyPollDensity(personalized, pollByPost)
		}
		if len(personalized) > 500 {
			personalized = personalized[:500]
		}
		personalized = applyExploration(personalized, candidates, features, now)
	}

	// FEED-V5：独立算法版本，v5 rollout 优先于 v4 rollout。
	if v5Active {
		v5Candidates := append([]HomeFeedCandidate(nil), candidates...)
		for i := range v5Candidates {
			v5Candidates[i].PersonalDelta = ComputePersonalDelta(v5Candidates[i], features, now)
			ScoreHomeFeedCandidateV5(&v5Candidates[i], now)
		}
		v5Ranked := RankHomeFeedV5(v5Candidates, now)
		if s.includePoll {
			v5Ranked = applyPollDensity(v5Ranked, pollByPost)
		}
		if len(v5Ranked) > 500 {
			v5Ranked = v5Ranked[:500]
		}
		v5Ranked = applyExploration(v5Ranked, v5Candidates, features, now)
		if s.v5Shadow {
			s.saveRankTrace(ctx, userID, fmt.Sprintf("%d", now.UnixNano()), v5Candidates, features, v5Ranked, now, personalizationAlgorithmVersionV5())
		}
		if s.v5RolloutPercent > 0 && userInRollout(userID, s.v5RolloutPercent) {
			return v5Ranked, nil
		}
		if s.v5Shadow {
			// 纯 shadow 的 V5 实验：保持与 baseline 对照，抑制 v4 rollout 干扰。
			return baseline, nil
		}
	}

	if s.personalizationShadow {
		s.saveRankTrace(ctx, userID, fmt.Sprintf("%d", now.UnixNano()), candidates, features, personalized, now, personalizationAlgorithmVersion())
	}
	if s.rolloutPercent > 0 && userInRollout(userID, s.rolloutPercent) {
		return personalized, nil
	}
	return baseline, nil
}

// personalizationAlgorithmVersion 返回个性化算法版本标识（shadow 仍可用 v4 追踪）。
func personalizationAlgorithmVersion() string {
	return "home_all_v4_personalized"
}

// personalizationAlgorithmVersionV5 FEED-V5 算法版本标识。
func personalizationAlgorithmVersionV5() string {
	return "home_all_v5_personalized"
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
