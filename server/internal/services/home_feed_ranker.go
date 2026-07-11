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
	Quality            float64
	HotScore           float64
	ActivityScore      float64
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
}

// RankHomeFeed 生成第一页混合槽位，其余候选按稳定热度顺序追加。
func RankHomeFeed(candidates []HomeFeedCandidate, now time.Time) []uint {
	for i := range candidates {
		ScoreHomeFeedCandidate(&candidates[i], now)
	}
	byHot := append([]HomeFeedCandidate(nil), candidates...)
	byFresh := append([]HomeFeedCandidate(nil), candidates...)
	byActivity := append([]HomeFeedCandidate(nil), candidates...)
	byFeatured := append([]HomeFeedCandidate(nil), candidates...)
	sort.SliceStable(byHot, func(i, j int) bool { return candidateLess(byHot[i], byHot[j], byHot[i].HotScore, byHot[j].HotScore) })
	sort.SliceStable(byFresh, func(i, j int) bool {
		return candidateLess(byFresh[i], byFresh[j], -float64(byFresh[i].Post.CreatedAt.UnixNano()), -float64(byFresh[j].Post.CreatedAt.UnixNano()))
	})
	sort.SliceStable(byActivity, func(i, j int) bool {
		return candidateLess(byActivity[i], byActivity[j], byActivity[i].ActivityScore, byActivity[j].ActivityScore)
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
			if !seen[item.Post.ID] && predicate(item) && canPlace(item, selected, now) {
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
			if seen[item.Post.ID] || !canPlace(item, selected, now) {
				continue
			}
			if len(selected) < 10 && item.Post.CreatedAt.Before(now.Add(-14*24*time.Hour)) && !item.Post.IsFeatured && item.Post.LastActivityAt.Before(now.Add(-72*time.Hour)) {
				continue
			}
			selected = append(selected, item)
			seen[item.Post.ID] = true
		}
	}
	// 如候选充足但硬约束阻塞，则逐级放宽，保证首页能返回完整页面。
	for _, item := range byHot {
		if len(selected) >= 20 {
			break
		}
		if !seen[item.Post.ID] {
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

func canPlace(candidate HomeFeedCandidate, selected []HomeFeedCandidate, now time.Time) bool {
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
	if len(selected) < 10 && author >= 2 {
		return false
	}
	if len(selected) >= 10 && author >= 3 {
		return false
	}
	if len(selected) < 10 && section >= 4 {
		return false
	}
	if len(selected) >= 10 && section >= 6 {
		return false
	}
	if candidate.Post.CreatedAt.Before(now.Add(-14*24*time.Hour)) && old >= 2 {
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
