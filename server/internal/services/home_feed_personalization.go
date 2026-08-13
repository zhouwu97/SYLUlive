package services

import (
	"context"
	"crypto/sha256"
	"fmt"
	"sort"
	"time"

	"shenliyuan/internal/models"
)

// userInRollout 稳定分桶：hash(userID) % 100 < percent 才放量（FEED-5 §31）。
func userInRollout(userID uint, percent int) bool {
	if percent <= 0 {
		return false
	}
	if percent >= 100 {
		return true
	}
	sum := sha256.Sum256([]byte(fmt.Sprintf("feed-v1:%d", userID)))
	return int(sum[0])%100 < percent
}

// shouldTrace 约 5% 采样（FEED-5 §30）。
func shouldTrace(userID uint) bool {
	sum := sha256.Sum256([]byte(fmt.Sprintf("feed-trace:%d", userID)))
	return int(sum[0])%20 == 0
}

// applyExploration 在个性化结果的第一页 20 条中，用探索候选替换固定槽位（5/11/17，
// 即 0-based 4/10/16）。探索来源取 deep feed（排名 20 之后）中探索分高的帖子：
// 新帖 + 用户未深度接触的版块/作者。
//
// 必须使用"交换"而非"覆盖"：覆盖会把深位帖子原地保留，导致同一 ID 重复出现，
// 同时让被顶出的 top-20 帖子凭空消失。交换保持长度、ID 集合与唯一性不变。
func applyExploration(
	ranked []uint,
	candidates []HomeFeedCandidate,
	features UserFeedFeatures,
	now time.Time,
) []uint {
	if len(ranked) < 20 {
		return ranked
	}
	byID := map[uint]HomeFeedCandidate{}
	for _, c := range candidates {
		byID[c.Post.ID] = c
	}
	// 探索候选池：排名 20 之后的 deep feed 帖子，按探索分排序。
	// 只有探索分 > 0 的帖子才允许进入探索池，避免“随机把深层帖子提上来”。
	type explore struct {
		id    uint
		score float64
	}
	var pool []explore
	for i := 20; i < len(ranked); i++ {
		c, ok := byID[ranked[i]]
		if !ok {
			continue
		}
		score := 0.0
		age := now.Sub(c.Post.CreatedAt).Hours()
		if age < 24 {
			score += 1.0
		} else if age < 48 {
			score += 0.5
		}
		if features.SectionAffinity(c.Post.PostType) < 0.2 {
			score += 0.8
		}
		if features.AuthorAffinity(c.Post.AuthorID) < 0.2 {
			score += 0.4
		}
		if score <= 0 {
			continue
		}
		pool = append(pool, explore{id: c.Post.ID, score: score})
	}
	sort.SliceStable(pool, func(i, j int) bool { return pool[i].score > pool[j].score })

	result := append([]uint(nil), ranked...)
	for _, slot := range []int{4, 10, 16} {
		if len(result) <= slot || len(pool) == 0 {
			break
		}
		exploreID := pool[0].id
		pool = pool[1:]
		// 找到该探索帖在深位（≥20）的原始位置，与之交换。
		deepPos := -1
		for i := 20; i < len(result); i++ {
			if result[i] == exploreID {
				deepPos = i
				break
			}
		}
		if deepPos < 0 || deepPos == slot {
			continue
		}
		result[slot], result[deepPos] = result[deepPos], result[slot]
	}
	return result
}

// saveRankTrace 记录个性化排序追踪（5% 采样；FEED-5 §30）。
// 只在命中采样时写入；失败不阻塞排序。
func (s *HomeFeedService) saveRankTrace(
	ctx context.Context,
	userID uint,
	snapshotID string,
	candidates []HomeFeedCandidate,
	features UserFeedFeatures,
	ranked []uint,
	now time.Time,
	version string,
) {
	if !shouldTrace(userID) {
		return
	}
	byID := map[uint]HomeFeedCandidate{}
	for _, c := range candidates {
		byID[c.Post.ID] = c
	}
	rows := make([]models.FeedRankTrace, 0, len(ranked))
	for position, id := range ranked {
		c, ok := byID[id]
		if !ok {
			continue
		}
		followSignal := 0.0
		if features.FollowedAuthors[c.Post.AuthorID] &&
			now.Sub(c.Post.CreatedAt) < 48*time.Hour {
			followSignal = 0.08
		}
		seenPenalty := 0.0
		if sessions := features.SeenSessionsByPost[c.Post.ID]; sessions >= 2 {
			if !features.SeenOpenedPostIDs[c.Post.ID] {
				seenPenalty = -0.15
			}
		}
		rows = append(rows, models.FeedRankTrace{
			UserID:           userID,
			SnapshotID:       snapshotID,
			PostID:           id,
			Position:         position,
			HotScore:         c.HotScore,
			ActivityScore:    c.ActivityScore,
			AuthorAffinity:   features.AuthorAffinity(c.Post.AuthorID),
			SectionAffinity:  features.SectionAffinity(c.Post.PostType),
			FollowSignal:     followSignal,
			SeenPenalty:      seenPenalty,
			PersonalDelta:    clampPersonalDelta(c.PersonalDelta),
			FinalScore:       AdjustedHotScore(c),
			ReasonCodes:      "personalized",
			AlgorithmVersion: version,
			CreatedAt:        now,
		})
	}
	if len(rows) == 0 {
		return
	}
	// 批量写入，失败静默（追踪不影响排序）。
	_ = s.db.WithContext(ctx).Create(&rows).Error
}
