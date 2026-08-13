package services

import (
	"context"
	"math"
	"time"

	"shenliyuan/internal/models"
)

// UserFeedFeatures 用户 Feed 个性化特征（FEED-5 / FEED-V5）。
//
// 全部按 30 天窗口批量聚合，权重做时间衰减（0.95^daysAgo）。
// 只依赖现有表：likes / replies / feed_impressions / user_follows / water_section_follows。
type UserFeedFeatures struct {
	UserID uint

	LikedAuthorCount   map[uint]float64
	RepliedAuthorCount map[uint]float64
	OpenedAuthorCount  map[uint]float64
	DwellByAuthorMS    map[uint]float64

	LikedSectionCount  map[string]float64
	OpenedSectionCount map[string]float64

	// FEED-V5：评论点赞/回复是"内容主题兴趣"信号，只累计到版块，
	// 不直接等同于"喜欢评论作者"。
	ReplyLikedSectionCount map[string]float64
	RepliedSectionCount    map[string]float64

	FollowedAuthors  map[uint]bool
	FollowedSections map[string]bool

	SeenPostIDs        map[uint]bool
	SeenSessionsByPost map[uint]int
	SeenOpenedPostIDs  map[uint]bool

	// HasSignal 为 true 表示有任一可参考信号；否则走冷启动（PersonalDelta=0）。
	HasSignal bool
}

func decay(createdAt, now time.Time) float64 {
	days := now.Sub(createdAt).Hours() / 24
	if days < 0 {
		days = 0
	}
	return math.Pow(0.95, days)
}

// saturation 平滑饱和：sat(x, k) = 1 - exp(-x/k)。
// 与 math.Min(1, count) 不同，互动 1/3/8 次时兴趣逐步递增，
// 但次数再多也不会权重爆炸。
func saturation(count float64, k float64) float64 {
	if count <= 0 {
		return 0
	}
	if k <= 0 {
		return 1
	}
	return 1 - math.Exp(-count/k)
}

// maxDwellPerEventMS 单次打开最多计 120s dwell（FEED-V5），
// 防止"打开帖子放后台 20 分钟"被解释成超强兴趣。
const maxDwellPerEventMS = int64(120 * 1000)

// BuildUserFeatures 批量聚合用户 30 天 Feed 特征（FEED-5 §28）。
// candidateIDs 用于 SeenPenalty（只统计候选帖子），可为空。
func (s *HomeFeedService) BuildUserFeatures(
	ctx context.Context,
	userID uint,
	candidateIDs []uint,
	now time.Time,
) UserFeedFeatures {
	features := UserFeedFeatures{
		UserID:                 userID,
		LikedAuthorCount:       map[uint]float64{},
		RepliedAuthorCount:     map[uint]float64{},
		OpenedAuthorCount:      map[uint]float64{},
		DwellByAuthorMS:        map[uint]float64{},
		LikedSectionCount:      map[string]float64{},
		OpenedSectionCount:     map[string]float64{},
		ReplyLikedSectionCount: map[string]float64{},
		RepliedSectionCount:    map[string]float64{},
		FollowedAuthors:        map[uint]bool{},
		FollowedSections:       map[string]bool{},
		SeenPostIDs:            map[uint]bool{},
		SeenSessionsByPost:     map[uint]int{},
		SeenOpenedPostIDs:      map[uint]bool{},
	}
	if userID == 0 {
		return features
	}
	cutoff := now.Add(-30 * 24 * time.Hour)

	// 关注作者 / 关注版块。
	var followedAuthors []uint
	if err := s.db.WithContext(ctx).Model(&models.UserFollow{}).
		Where("follower_id = ?", userID).Pluck("following_id", &followedAuthors).Error; err == nil {
		for _, id := range followedAuthors {
			features.FollowedAuthors[id] = true
			features.HasSignal = true
		}
	}
	var followedSections []string
	if err := s.db.WithContext(ctx).
		Model(&models.WaterSectionFollow{}).
		Joins("JOIN water_sections ON water_sections.id = water_section_follows.section_id").
		Select("water_sections.slug").
		Where("water_section_follows.user_id = ?", userID).
		Pluck("slug", &followedSections).Error; err == nil {
		for _, slug := range followedSections {
			features.FollowedSections[slug] = true
			features.HasSignal = true
		}
	}

	type postSignal struct {
		AuthorID  uint
		PostType  string
		CreatedAt time.Time
	}

	// likes → 帖子作者/版块。
	var liked []postSignal
	if err := s.db.WithContext(ctx).
		Table("likes l").
		Select("p.author_id AS author_id, p.post_type AS post_type, l.created_at AS created_at").
		Joins("JOIN posts p ON p.id = l.target_id").
		Where("l.user_id = ? AND l.target_type = ? AND l.created_at >= ?", userID, "post", cutoff).
		Scan(&liked).Error; err == nil {
		for _, row := range liked {
			features.LikedAuthorCount[row.AuthorID] += decay(row.CreatedAt, now)
			if row.PostType != "" {
				features.LikedSectionCount[row.PostType] += decay(row.CreatedAt, now)
			}
			features.HasSignal = true
		}
	}

	// reply_likes → 评论点赞是"内容主题兴趣"信号：Like(reply) → reply.post_id →
	// post.post_type → ReplyLikedSectionCount。只累计版块，不累计作者。
	var replyLiked []postSignal
	if err := s.db.WithContext(ctx).
		Table("likes l").
		Select("p.post_type AS post_type, l.created_at AS created_at").
		Joins("JOIN replies r ON r.id = l.target_id").
		Joins("JOIN posts p ON p.id = r.post_id").
		Where("l.user_id = ? AND l.target_type = ? AND l.created_at >= ?", userID, "reply", cutoff).
		Scan(&replyLiked).Error; err == nil {
		for _, row := range replyLiked {
			if row.PostType != "" {
				features.ReplyLikedSectionCount[row.PostType] += decay(row.CreatedAt, now)
			}
			features.HasSignal = true
		}
	}

	// replies → 帖子作者/版块（RepliedSectionCount 是现成数据，V4 未累计）。
	var replied []postSignal
	if err := s.db.WithContext(ctx).
		Table("replies r").
		Select("p.author_id AS author_id, p.post_type AS post_type, r.created_at AS created_at").
		Joins("JOIN posts p ON p.id = r.post_id").
		Where("r.author_id = ? AND r.status = ? AND r.created_at >= ?", userID, models.ReplyStatusNormal, cutoff).
		Scan(&replied).Error; err == nil {
		for _, row := range replied {
			features.RepliedAuthorCount[row.AuthorID] += decay(row.CreatedAt, now)
			if row.PostType != "" {
				features.RepliedSectionCount[row.PostType] += decay(row.CreatedAt, now)
			}
			features.HasSignal = true
		}
	}

	// opens / dwell → 帖子作者/版块（feed_impressions）。
	type impSignal struct {
		AuthorID  uint
		PostType  string
		DwellMS   int
		CreatedAt time.Time
	}
	var opens []impSignal
	if err := s.db.WithContext(ctx).
		Table("feed_impressions fi").
		Select("p.author_id AS author_id, p.post_type AS post_type, fi.dwell_ms AS dwell_ms, fi.created_at AS created_at").
		Joins("JOIN posts p ON p.id = fi.post_id").
		Where("fi.user_id = ? AND fi.opened_at IS NOT NULL AND fi.created_at >= ?", userID, cutoff).
		Scan(&opens).Error; err == nil {
		for _, row := range opens {
			features.OpenedAuthorCount[row.AuthorID] += decay(row.CreatedAt, now)
			if row.PostType != "" {
				features.OpenedSectionCount[row.PostType] += decay(row.CreatedAt, now)
			}
			// FEED-V5：dwell 必须按时间衰减，且单次 cap 120s。
			if row.DwellMS > 0 {
				bounded := int64(row.DwellMS)
				if bounded > maxDwellPerEventMS {
					bounded = maxDwellPerEventMS
				}
				features.DwellByAuthorMS[row.AuthorID] += float64(bounded) * decay(row.CreatedAt, now)
			}
			features.HasSignal = true
		}
	}

	// seen：候选帖子的曝光 session 数（SeenPenalty 用）。
	if len(candidateIDs) > 0 {
		type seenRow struct {
			PostID        uint
			FeedSessionID string
			OpenedAt      *time.Time
		}
		var seen []seenRow
		if err := s.db.WithContext(ctx).
			Model(&models.FeedImpression{}).
			Select("post_id, feed_session_id, opened_at").
			Where("user_id = ? AND post_id IN ? AND created_at >= ?", userID, candidateIDs, cutoff).
			Find(&seen).Error; err == nil {
			for _, row := range seen {
				features.SeenPostIDs[row.PostID] = true
				features.SeenSessionsByPost[row.PostID]++
				if row.OpenedAt != nil {
					features.SeenOpenedPostIDs[row.PostID] = true
				}
			}
		}
	}

	return features
}

// AuthorAffinity 归一化作者亲和（0~1）。
func (f UserFeedFeatures) AuthorAffinity(authorID uint) float64 {
	score := 0.0
	if f.FollowedAuthors[authorID] {
		score += 1.0
	}
	score += saturation(f.RepliedAuthorCount[authorID], 3) * 0.8
	score += saturation(f.LikedAuthorCount[authorID], 3) * 0.5
	if f.DwellByAuthorMS[authorID] >= 10*60*1000 {
		score += 0.4
	}
	score += saturation(f.OpenedAuthorCount[authorID], 5) * 0.2
	return math.Min(1.0, score)
}

// SectionAffinity 归一化版块亲和（0~1）。
// FEED-V5：评论点赞（ReplyLikedSectionCount）与评论（RepliedSectionCount）
// 是内容主题兴趣的强信号，权重低于帖子点赞但纳入计算。
func (f UserFeedFeatures) SectionAffinity(slug string) float64 {
	score := 0.0
	if f.FollowedSections[slug] {
		score += 1.0
	}
	score += saturation(f.LikedSectionCount[slug], 3) * 0.5
	score += saturation(f.OpenedSectionCount[slug], 5) * 0.2
	score += saturation(f.RepliedSectionCount[slug], 4) * 0.2
	score += saturation(f.ReplyLikedSectionCount[slug], 3) * 0.3
	return math.Min(1.0, score)
}

// ComputePersonalDelta 计算单帖个性化增量（FEED-5 §28.x）。
// 冷启动（无信号）返回 0；范围由 clampPersonalDelta 限到 ±0.20。
func ComputePersonalDelta(c HomeFeedCandidate, features UserFeedFeatures, now time.Time) float64 {
	if !features.HasSignal {
		return 0
	}
	var delta float64
	delta += features.AuthorAffinity(c.Post.AuthorID) * 0.10
	delta += features.SectionAffinity(c.Post.PostType) * 0.06
	// FollowSignal：关注作者的 48h 新帖给强信号。
	if features.FollowedAuthors[c.Post.AuthorID] &&
		now.Sub(c.Post.CreatedAt) < 48*time.Hour {
		delta += 0.08
	}
	// Freshness：48h 新帖小幅加成。
	if now.Sub(c.Post.CreatedAt) < 48*time.Hour {
		delta += 0.04
	}
	// SeenPenalty：不同 session ≥2 次曝光且从未 open。
	if sessions := features.SeenSessionsByPost[c.Post.ID]; sessions >= 2 {
		if !features.SeenOpenedPostIDs[c.Post.ID] {
			delta -= 0.15
		}
	}
	return clampPersonalDelta(delta)
}
