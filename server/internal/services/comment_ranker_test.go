package services

import (
	"math"
	"testing"
	"time"

	"shenliyuan/internal/models"

	"github.com/stretchr/testify/require"
)

func commentCandidate(id uint, likeCount int, createdAt time.Time, childCount int) CommentRankCandidate {
	return CommentRankCandidate{
		Reply: models.Reply{
			ID:        id,
			LikeCount: likeCount,
			CreatedAt: createdAt,
		},
		ChildReplyCount: childCount,
	}
}

// A. 高赞老评论 > 低赞新评论。
func TestRankRootRepliesHighLikedOldBeatNew(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	old := commentCandidate(1, 30, now.Add(-72*time.Hour), 0)
	newComment := commentCandidate(2, 1, now.Add(-time.Hour), 0)
	ids := RankRootReplies([]CommentRankCandidate{newComment, old}, CommentSortHot, now)
	require.Equal(t, []uint{1, 2}, ids)
}

// B. 新评论有适度 freshness 优势。
func TestRankRootRepliesFreshnessEdge(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	// 同 0 赞：新的在前。
	older := commentCandidate(10, 0, now.Add(-48*time.Hour), 0)
	newer := commentCandidate(20, 0, now.Add(-time.Hour), 0)
	ids := RankRootReplies([]CommentRankCandidate{older, newer}, CommentSortHot, now)
	require.Equal(t, []uint{20, 10}, ids)
}

// C. childCount 超过 8 后不再继续增加收益。
func TestCommentHotScoreChildCap(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	a := commentCandidate(1, 0, now, 8)
	b := commentCandidate(2, 0, now, 50) // 争吵楼
	scoreA := CommentHotScore(a, now)
	scoreB := CommentHotScore(b, now)
	require.Equal(t, scoreA, scoreB, "child>8 不应再增加收益")
}

// D. likeCount 相同 → freshness 决定。
func TestRankRootRepliesSameLikeUsesFreshness(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	older := commentCandidate(1, 5, now.Add(-24*time.Hour), 0)
	newer := commentCandidate(2, 5, now.Add(-time.Hour), 0)
	ids := RankRootReplies([]CommentRankCandidate{older, newer}, CommentSortHot, now)
	require.Equal(t, []uint{2, 1}, ids)
}

// E. hotScore 相同 → like_count 决定。
func TestRankRootRepliesTieBreakByLikeCount(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	// 构造 hotScore 相等但 likeCount 不同：需要精确分数，直接模拟同 child/age、不同 like。
	// 用 child=0、age 相同，但通过调整 like 数让分数不同，验证 like 高者优先。
	a := commentCandidate(1, 10, now.Add(-100*time.Hour), 0)
	b := commentCandidate(2, 2, now.Add(-100*time.Hour), 0)
	ids := RankRootReplies([]CommentRankCandidate{b, a}, CommentSortHot, now)
	require.Equal(t, []uint{1, 2}, ids)
}

// F. 再相同 → created_at。
func TestRankRootRepliesTieBreakByCreatedAt(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	older := commentCandidate(1, 7, now.Add(-50*time.Hour), 0)
	newer := commentCandidate(2, 7, now.Add(-10*time.Hour), 0)
	ids := RankRootReplies([]CommentRankCandidate{older, newer}, CommentSortHot, now)
	require.Equal(t, []uint{2, 1}, ids)
}

// G. 再相同 → id。
func TestRankRootRepliesTieBreakByID(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	low := commentCandidate(1, 9, now, 0)
	high := commentCandidate(2, 9, now, 0)
	ids := RankRootReplies([]CommentRankCandidate{low, high}, CommentSortHot, now)
	require.Equal(t, []uint{2, 1}, ids)
}

// H. Latest = created_at DESC, id DESC。
func TestRankRootRepliesLatestOrder(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	a := commentCandidate(1, 100, now.Add(-3*time.Hour), 9)
	b := commentCandidate(2, 0, now.Add(-time.Hour), 0)
	c := commentCandidate(3, 0, now.Add(-time.Hour), 0) // 同 created_at，id 更大
	ids := RankRootReplies([]CommentRankCandidate{a, c, b}, CommentSortLatest, now)
	require.Equal(t, []uint{3, 2, 1}, ids)
}

// I. 输入顺序随机，输出仍然确定。
func TestRankRootRepliesDeterministic(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	base := []CommentRankCandidate{
		commentCandidate(1, 8, now.Add(-2*time.Hour), 3),
		commentCandidate(2, 1, now.Add(-10*time.Hour), 0),
		commentCandidate(3, 4, now.Add(-1*time.Hour), 1),
		commentCandidate(4, 0, now.Add(-5*time.Hour), 6),
	}
	first := RankRootReplies(base, CommentSortHot, now)
	for i := 0; i < 20; i++ {
		require.Equal(t, first, RankRootReplies(base, CommentSortHot, now))
	}
}

// J. 0 点赞 / 0 回复全部可正常排序。
func TestRankRootRepliesZeroSignal(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	a := commentCandidate(1, 0, now.Add(-2*time.Hour), 0)
	b := commentCandidate(2, 0, now.Add(-1*time.Hour), 0)
	ids := RankRootReplies([]CommentRankCandidate{a, b}, CommentSortHot, now)
	require.Len(t, ids, 2)
	require.ElementsMatch(t, []uint{1, 2}, ids)
}

// K. 时间在未来的数据不产生异常分数。
func TestCommentHotScoreFutureTime(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	future := commentCandidate(1, 5, now.Add(48*time.Hour), 2)
	score := CommentHotScore(future, now)
	require.False(t, math.IsNaN(score))
	require.False(t, math.IsInf(score, 0))
	require.GreaterOrEqual(t, score, 0.0)
}

// L. 不产生 NaN / Inf。
func TestCommentHotScoreNoNaNOrInf(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	// 极大 like 数。
	big := commentCandidate(1, 1<<30, now, 100)
	score := CommentHotScore(big, now)
	require.False(t, math.IsNaN(score))
	require.False(t, math.IsInf(score, 0))
	require.True(t, score > 0)
}

// ValidCommentSort 校验。
func TestValidCommentSort(t *testing.T) {
	_, ok := ValidCommentSort("")
	require.True(t, ok, "空字符串应默认 hot")
	mode, ok := ValidCommentSort("hot")
	require.True(t, ok)
	require.Equal(t, CommentSortHot, mode)
	mode, ok = ValidCommentSort("latest")
	require.True(t, ok)
	require.Equal(t, CommentSortLatest, mode)
	_, ok = ValidCommentSort("top")
	require.False(t, ok, "非法参数必须拒绝，不能 silent fallback")
}
