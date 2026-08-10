package services

import (
	"math"
	"sort"
	"time"

	"shenliyuan/internal/models"
)

// HomeFeedCandidate 是首页排序所需的最小帖子数据，排序器不依赖 HTTP 或数据库。
type HomeFeedCandidate struct {
	Post               models.Post
	UniqueReplierCount int64
	IsPoll             bool
	PollLastVoteAt     *time.Time
	ParticipantCount   int
	PollEnded          bool
	Quality            float64
	HotScore           float64
	ActivityScore      float64
	// FEED-5 个性化增量（-0.20 ~ +0.20），由个性化层在排序前写入；0 = 不个性化。
	PersonalDelta float64
}

// clampPersonalDelta 限制个性化增量范围，避免画像把公共质量压没。
func clampPersonalDelta(delta float64) float64 {
	if delta < -0.20 {
		return -0.20
	}
	if delta > 0.20 {
		return 0.20
	}
	return delta
}

// AdjustedHotScore 个性化后的热度分：HotScore * (1 + delta)。
func AdjustedHotScore(c HomeFeedCandidate) float64 {
	return c.HotScore * (1 + clampPersonalDelta(c.PersonalDelta))
}

// AdjustedActivityScore 个性化后的活跃分：ActivityScore * (1 + delta)。
func AdjustedActivityScore(c HomeFeedCandidate) float64 {
	return c.ActivityScore * (1 + clampPersonalDelta(c.PersonalDelta))
}

func ScoreHomeFeedCandidate(candidate *HomeFeedCandidate, now time.Time) {
	effectiveReplies := math.Min(float64(candidate.Post.ReplyCount), float64(candidate.UniqueReplierCount*3+5))
	candidate.Quality = 4*math.Log1p(float64(candidate.Post.LikeCount)) +
		6*math.Log1p(float64(candidate.UniqueReplierCount)) +
		2*math.Log1p(effectiveReplies) + 0.8*math.Log1p(float64(candidate.Post.ViewCount))
	publishedAge := math.Max(now.Sub(candidate.Post.CreatedAt).Hours(), 0)
	activityAt := candidate.Post.LastActivityAt
	if activityAt.IsZero() {
		activityAt = candidate.Post.CreatedAt
	}
	activityAge := math.Max(now.Sub(activityAt).Hours(), 0)
	candidate.HotScore = (6 + candidate.Quality) / math.Pow(publishedAge+6, 0.9)
	candidate.ActivityScore = (4 + candidate.Quality) / math.Pow(activityAge+4, 0.8)
	if candidate.IsPoll {
		participantBonus := math.Min(3.5, math.Log1p(float64(candidate.ParticipantCount)))
		voteActivityBonus := 0.0
		if candidate.PollLastVoteAt != nil {
			voteAge := math.Max(now.Sub(*candidate.PollLastVoteAt).Hours(), 0)
			voteActivityBonus = math.Min(3, 3/(1+voteAge/12))
		}
		candidate.HotScore += participantBonus + voteActivityBonus
		candidate.ActivityScore += participantBonus*0.5 + voteActivityBonus
		if candidate.PollEnded {
			candidate.HotScore *= 0.35
			candidate.ActivityScore *= 0.35
		}
	}
}

type PlacementPolicy struct {
	MaxAuthorFirst10  int
	MaxAuthorPage     int
	MaxSectionFirst10 int
	MaxSectionPage    int
	MaxOldPosts       int
	MaxAge            time.Duration
}

var (
	StrictPolicy = PlacementPolicy{
		MaxAuthorFirst10:  2,
		MaxAuthorPage:     3,
		MaxSectionFirst10: 4,
		MaxSectionPage:    6,
		MaxOldPosts:       2,
		MaxAge:            0,
	}
	RelaxedPolicy1 = PlacementPolicy{
		MaxAuthorFirst10:  2,
		MaxAuthorPage:     3,
		MaxSectionFirst10: 6,
		MaxSectionPage:    10,
		MaxOldPosts:       2,
		MaxAge:            0,
	}
	RelaxedPolicy2 = PlacementPolicy{
		MaxAuthorFirst10:  2,
		MaxAuthorPage:     4,
		MaxSectionFirst10: 6,
		MaxSectionPage:    10,
		MaxOldPosts:       2,
		MaxAge:            0,
	}
	FinalFillPolicy = PlacementPolicy{
		MaxAuthorFirst10:  10,
		MaxAuthorPage:     20,
		MaxSectionFirst10: 10,
		MaxSectionPage:    20,
		MaxOldPosts:       2,
		MaxAge:            0,
	}
)

// RankHomeFeed 生成第一页混合槽位，其余候选按稳定热度顺序追加。
func RankHomeFeed(candidates []HomeFeedCandidate, now time.Time) []uint {
	for i := range candidates {
		ScoreHomeFeedCandidate(&candidates[i], now)
	}
	byHot := append([]HomeFeedCandidate(nil), candidates...)
	byFresh := append([]HomeFeedCandidate(nil), candidates...)
	byActivity := append([]HomeFeedCandidate(nil), candidates...)
	byFeatured := append([]HomeFeedCandidate(nil), candidates...)
	sort.SliceStable(byHot, func(i, j int) bool {
		return candidateLess(byHot[i], byHot[j], AdjustedHotScore(byHot[i]), AdjustedHotScore(byHot[j]))
	})
	sort.SliceStable(byFresh, func(i, j int) bool {
		left := byFresh[i].Post.CreatedAt
		right := byFresh[j].Post.CreatedAt
		if !left.Equal(right) {
			return left.After(right)
		}
		return byFresh[i].Post.ID > byFresh[j].Post.ID
	})
	sort.SliceStable(byActivity, func(i, j int) bool {
		return candidateLess(byActivity[i], byActivity[j], AdjustedActivityScore(byActivity[i]), AdjustedActivityScore(byActivity[j]))
	})
	sort.SliceStable(byFeatured, func(i, j int) bool {
		left, right := byFeatured[i].Post.FeaturedAt, byFeatured[j].Post.FeaturedAt
		if left != nil && right != nil && !left.Equal(*right) {
			return left.After(*right)
		}
		if left != nil && right == nil {
			return true
		}
		if left == nil && right != nil {
			return false
		}
		return candidateLess(byFeatured[i], byFeatured[j], byFeatured[i].HotScore, byFeatured[j].HotScore)
	})
	selected := make([]HomeFeedCandidate, 0, minInt(20, len(candidates)))
	seen := map[uint]bool{}
	add := func(pool []HomeFeedCandidate, maximum int, predicate func(HomeFeedCandidate) bool) {
		for _, item := range pool {
			if len(selected) >= 20 || maximum == 0 {
				return
			}
			if !seen[item.Post.ID] && predicate(item) && canPlace(item, selected, now, StrictPolicy) {
				selected = append(selected, item)
				seen[item.Post.ID] = true
				maximum--
			}
		}
	}
	add(byHot, 10, func(c HomeFeedCandidate) bool { return !c.Post.CreatedAt.Before(now.Add(-7 * 24 * time.Hour)) })
	add(byFresh, 5, func(c HomeFeedCandidate) bool { return !c.Post.CreatedAt.Before(now.Add(-48 * time.Hour)) })
	add(byActivity, 3, func(c HomeFeedCandidate) bool {
		return c.Post.ReplyCount > 0 && !c.Post.LastActivityAt.Before(now.Add(-72*time.Hour))
	})
	add(byFeatured, 2, func(c HomeFeedCandidate) bool {
		return c.Post.IsFeatured && !c.Post.CreatedAt.Before(now.Add(-180*24*time.Hour))
	})
	// 槽位不足时按约定顺序补满；普通沉寂旧帖不会进前十。
	for _, pool := range [][]HomeFeedCandidate{byHot, byFresh, byActivity, byFeatured, candidates} {
		for _, item := range pool {
			if len(selected) >= 20 {
				break
			}
			if seen[item.Post.ID] || !canPlace(item, selected, now, StrictPolicy) {
				continue
			}
			selected = append(selected, item)
			seen[item.Post.ID] = true
		}
	}
	// 构造主候选池和 30 天普通补位池
	primaryPool := make([]HomeFeedCandidate, 0)
	recent30NormalPool := make([]HomeFeedCandidate, 0)
	inPrimary := make(map[uint]bool)

	for _, c := range byHot {
		isPrimary := false
		if !c.Post.CreatedAt.Before(now.Add(-7 * 24 * time.Hour)) {
			isPrimary = true
		} else if c.Post.ReplyCount > 0 && !c.Post.LastActivityAt.Before(now.Add(-72*time.Hour)) {
			isPrimary = true
		} else if c.Post.IsFeatured && !c.Post.CreatedAt.Before(now.Add(-180*24*time.Hour)) {
			isPrimary = true
		}

		if isPrimary {
			primaryPool = append(primaryPool, c)
			inPrimary[c.Post.ID] = true
		}
	}

	for _, c := range byFresh {
		if !inPrimary[c.Post.ID] && !c.Post.IsFeatured && !c.Post.CreatedAt.Before(now.Add(-30*24*time.Hour)) {
			recent30NormalPool = append(recent30NormalPool, c)
		}
	}

	// 如候选充足但硬约束阻塞，则逐级放宽。
	relaxPolicies := []PlacementPolicy{RelaxedPolicy1, RelaxedPolicy2}
	for _, policy := range relaxPolicies {
		if len(selected) >= 20 {
			break
		}
		for _, item := range primaryPool {
			if len(selected) >= 20 {
				break
			}
			if !seen[item.Post.ID] && canPlace(item, selected, now, policy) {
				selected = append(selected, item)
				seen[item.Post.ID] = true
			}
		}
	}

	// 第三级放宽：从最近 30 天尚未选中的普通帖子中补位，使用第二级放宽政策
	if len(selected) < 20 {
		for _, item := range recent30NormalPool {
			if len(selected) >= 20 {
				break
			}
			if !seen[item.Post.ID] && canPlace(item, selected, now, RelaxedPolicy2) {
				selected = append(selected, item)
				seen[item.Post.ID] = true
			}
		}
	}

	// 最终补位：完全放宽作者和版块，但继续限制老帖
	if len(selected) < 20 {
		for _, item := range byHot {
			if len(selected) >= 20 {
				break
			}
			if seen[item.Post.ID] || !canPlace(item, selected, now, FinalFillPolicy) {
				continue
			}
			selected = append(selected, item)
			seen[item.Post.ID] = true
		}
	}

	ids := make([]uint, 0, len(candidates))
	for _, item := range selected {
		ids = append(ids, item.Post.ID)
	}
	for _, item := range byHot {
		if !seen[item.Post.ID] {
			ids = append(ids, item.Post.ID)
			seen[item.Post.ID] = true
		}
	}
	return ids
}

func canPlace(candidate HomeFeedCandidate, selected []HomeFeedCandidate, now time.Time, policy PlacementPolicy) bool {
	author, section, old := 0, 0, 0
	for _, item := range selected {
		if item.Post.AuthorID == candidate.Post.AuthorID {
			author++
		}
		if item.Post.PostType == candidate.Post.PostType {
			section++
		}
		if item.Post.CreatedAt.Before(now.Add(-14 * 24 * time.Hour)) {
			old++
		}
	}
	if len(selected) < 10 && author >= policy.MaxAuthorFirst10 {
		return false
	}
	if len(selected) >= 10 && author >= policy.MaxAuthorPage {
		return false
	}
	if len(selected) < 10 && section >= policy.MaxSectionFirst10 {
		return false
	}
	if len(selected) >= 10 && section >= policy.MaxSectionPage {
		return false
	}
	if candidate.Post.CreatedAt.Before(now.Add(-14*24*time.Hour)) && old >= policy.MaxOldPosts {
		return false
	}
	if len(selected) < 10 && candidate.Post.CreatedAt.Before(now.Add(-14*24*time.Hour)) && !candidate.Post.IsFeatured && candidate.Post.LastActivityAt.Before(now.Add(-72*time.Hour)) {
		return false
	}
	if policy.MaxAge > 0 && candidate.Post.CreatedAt.Before(now.Add(-policy.MaxAge)) {
		return false
	}
	return true
}
func candidateLess(a, b HomeFeedCandidate, left, right float64) bool {
	if left != right {
		return left > right
	}
	aa, bb := a.Post.LastActivityAt, b.Post.LastActivityAt
	if !aa.Equal(bb) {
		return aa.After(bb)
	}
	if !a.Post.CreatedAt.Equal(b.Post.CreatedAt) {
		return a.Post.CreatedAt.After(b.Post.CreatedAt)
	}
	return a.Post.ID > b.Post.ID
}
func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
