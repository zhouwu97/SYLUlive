package services

import (
	"sort"
	"time"
)

// RankSectionFeed 生成单个版块的推荐顺序。
//
// 版块流和首页流的约束不同：版块内不再按 post_type 做多样性限制，
// 只保留“新帖、活跃帖、精华帖、热帖”的混合槽位，以及沉寂老帖上限。
func RankSectionFeed(candidates []HomeFeedCandidate, now time.Time, pinnedWeights map[uint]int) []uint {
	for i := range candidates {
		ScoreHomeFeedCandidate(&candidates[i], now)
	}

	byHot := append([]HomeFeedCandidate(nil), candidates...)
	byFresh := append([]HomeFeedCandidate(nil), candidates...)
	byActivity := append([]HomeFeedCandidate(nil), candidates...)
	byFeatured := append([]HomeFeedCandidate(nil), candidates...)
	byPinned := append([]HomeFeedCandidate(nil), candidates...)

	sort.SliceStable(byHot, func(i, j int) bool {
		return candidateLess(byHot[i], byHot[j], byHot[i].HotScore, byHot[j].HotScore)
	})
	sort.SliceStable(byFresh, func(i, j int) bool {
		if !byFresh[i].Post.CreatedAt.Equal(byFresh[j].Post.CreatedAt) {
			return byFresh[i].Post.CreatedAt.After(byFresh[j].Post.CreatedAt)
		}
		return byFresh[i].Post.ID > byFresh[j].Post.ID
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
	sort.SliceStable(byPinned, func(i, j int) bool {
		left, right := pinnedWeights[byPinned[i].Post.ID], pinnedWeights[byPinned[j].Post.ID]
		if left != right {
			return left > right
		}
		return candidateLess(byPinned[i], byPinned[j], byPinned[i].HotScore, byPinned[j].HotScore)
	})

	selected := make([]HomeFeedCandidate, 0, minInt(20, len(candidates)))
	seen := make(map[uint]bool, len(candidates))
	add := func(pool []HomeFeedCandidate, maximum int, predicate func(HomeFeedCandidate) bool) {
		for _, item := range pool {
			if len(selected) >= 20 || maximum == 0 {
				return
			}
			if seen[item.Post.ID] || !predicate(item) || !canPlaceSectionPost(item, selected, now, pinnedWeights) {
				continue
			}
			selected = append(selected, item)
			seen[item.Post.ID] = true
			maximum--
		}
	}

	// 版块局部置顶优先于推荐槽位，但仍受单页 20 条上限约束。
	for _, item := range byPinned {
		if len(selected) >= 20 {
			break
		}
		if _, pinned := pinnedWeights[item.Post.ID]; !pinned || seen[item.Post.ID] {
			continue
		}
		selected = append(selected, item)
		seen[item.Post.ID] = true
	}

	// 推荐页槽位：7 天热帖 8 条、48 小时新帖 6 条、72 小时活跃帖 3 条、精华 2 条。
	add(byHot, 8, func(item HomeFeedCandidate) bool {
		return !item.Post.CreatedAt.Before(now.Add(-7 * 24 * time.Hour))
	})
	add(byFresh, 6, func(item HomeFeedCandidate) bool {
		return !item.Post.CreatedAt.Before(now.Add(-48 * time.Hour))
	})
	add(byActivity, 3, func(item HomeFeedCandidate) bool {
		return item.Post.ReplyCount > 0 && !sectionActivityAt(item).Before(now.Add(-72*time.Hour))
	})
	add(byFeatured, 2, func(item HomeFeedCandidate) bool {
		return item.Post.IsFeatured
	})

	// 其他内容只占一个首屏补位槽；后续内容仍按稳定热度顺序返回。
	add(byHot, 1, func(HomeFeedCandidate) bool { return true })
	for _, item := range byHot {
		if seen[item.Post.ID] || !canPlaceSectionPost(item, selected, now, pinnedWeights) {
			continue
		}
		if len(selected) >= 20 {
			break
		}
		selected = append(selected, item)
		seen[item.Post.ID] = true
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

func canPlaceSectionPost(candidate HomeFeedCandidate, selected []HomeFeedCandidate, now time.Time, pinnedWeights map[uint]int) bool {
	if _, pinned := pinnedWeights[candidate.Post.ID]; pinned {
		return true
	}
	if !isDormantSectionPost(candidate, now) {
		return true
	}

	limit := 2
	if len(selected) < 10 {
		limit = 1
	}
	oldCount := 0
	for _, item := range selected {
		if _, itemPinned := pinnedWeights[item.Post.ID]; !itemPinned && isDormantSectionPost(item, now) {
			oldCount++
		}
	}
	return oldCount < limit
}

func isDormantSectionPost(candidate HomeFeedCandidate, now time.Time) bool {
	return candidate.Post.CreatedAt.Before(now.Add(-14*24*time.Hour)) &&
		!candidate.Post.IsFeatured &&
		sectionActivityAt(candidate).Before(now.Add(-72*time.Hour))
}

func sectionActivityAt(candidate HomeFeedCandidate) time.Time {
	if candidate.Post.LastActivityAt.IsZero() {
		return candidate.Post.CreatedAt
	}
	return candidate.Post.LastActivityAt
}
