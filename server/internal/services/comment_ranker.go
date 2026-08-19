package services

import (
	"math"
	"sort"
	"time"

	"shenliyuan/internal/models"
)

// CommentSort 评论排序模式。
type CommentSort string

const (
	// CommentSortHot 热门：quality + freshness，只作用于一级评论线程。
	CommentSortHot CommentSort = "hot"
	// CommentSortLatest 最新：一级评论按发布时间倒序。
	CommentSortLatest CommentSort = "latest"
)

// ValidCommentSort 校验排序参数；空字符串按 hot 处理（旧客户端不传 sort）。
func ValidCommentSort(raw string) (CommentSort, bool) {
	switch CommentSort(raw) {
	case "":
		return CommentSortHot, true
	case CommentSortHot, CommentSortLatest:
		return CommentSort(raw), true
	default:
		return "", false
	}
}

// CommentRankCandidate 是评论排序所需的最小数据，排序器不依赖 HTTP / GORM。
type CommentRankCandidate struct {
	Reply           models.Reply
	ChildReplyCount int
}

// RankRootReplies 对一级评论排序，返回排序后的回复 ID 列表。
//
// Hot：hot_score DESC → like_count DESC → created_at DESC → id DESC（确定性 tie-breaker）。
// Latest：created_at DESC → id DESC。
//
// 只排序一级评论；子回复永远由调用方按 created_at ASC, id ASC 组装，
// 不进入 Ranker。now 必须由调用方显式传入，便于测试确定性。
func RankRootReplies(candidates []CommentRankCandidate, mode CommentSort, now time.Time) []uint {
	ranked := append([]CommentRankCandidate(nil), candidates...)
	switch mode {
	case CommentSortLatest:
		sort.SliceStable(ranked, func(i, j int) bool {
			if !ranked[i].Reply.CreatedAt.Equal(ranked[j].Reply.CreatedAt) {
				return ranked[i].Reply.CreatedAt.After(ranked[j].Reply.CreatedAt)
			}
			return ranked[i].Reply.ID > ranked[j].Reply.ID
		})
	default: // hot（含空字符串容错，但 ValidCommentSort 已统一解析）
		sort.SliceStable(ranked, func(i, j int) bool {
			left := CommentHotScore(ranked[i], now)
			right := CommentHotScore(ranked[j], now)
			if left != right {
				return left > right
			}
			if ranked[i].Reply.LikeCount != ranked[j].Reply.LikeCount {
				return ranked[i].Reply.LikeCount > ranked[j].Reply.LikeCount
			}
			if !ranked[i].Reply.CreatedAt.Equal(ranked[j].Reply.CreatedAt) {
				return ranked[i].Reply.CreatedAt.After(ranked[j].Reply.CreatedAt)
			}
			return ranked[i].Reply.ID > ranked[j].Reply.ID
		})
	}
	ids := make([]uint, 0, len(ranked))
	for _, c := range ranked {
		ids = append(ids, c.Reply.ID)
	}
	return ids
}

// CommentHotScore 计算一级评论热门分。
//
//	child = min(child_reply_count, 8)
//	quality = 2.5*ln(1+like_count) + 1.0*ln(1+child)
//	freshness = 0.5*exp(-age_hours/72)
//	hot_score = quality + freshness
//
// 点赞是主要质量信号；子回复数封顶 8 防止争吵楼被无限奖励；
// freshness 只给新评论一点竞争机会，72h 内衰减，不强制老评论报废。
func CommentHotScore(c CommentRankCandidate, now time.Time) float64 {
	child := float64(c.ChildReplyCount)
	if child > 8 {
		child = 8
	}
	quality := 2.5*math.Log1p(float64(c.Reply.LikeCount)) + 1.0*math.Log1p(child)
	ageHours := math.Max(now.Sub(c.Reply.CreatedAt).Hours(), 0)
	freshness := 0.5 * math.Exp(-ageHours/72)
	return quality + freshness
}
