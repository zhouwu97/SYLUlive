package services

import (
	"context"
	"math"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"shenliyuan/internal/models"
)

// ---- saturation ----

func TestSaturation(t *testing.T) {
	// x<=0 → 0。
	require.Equal(t, 0.0, saturation(0, 3))
	require.Equal(t, 0.0, saturation(-5, 3))
	// 1/3/8 次逐步递增但封顶到 1。
	s1 := saturation(1, 3)
	s3 := saturation(3, 3)
	s8 := saturation(8, 3)
	require.True(t, s1 > 0 && s1 < s3)
	require.True(t, s3 < s8)
	require.True(t, s8 < 1.0)
	require.True(t, saturation(1000, 3) > 0.99)
	// k<=0 防御。
	require.Equal(t, 1.0, saturation(1, 0))
}

// ---- dwell cap + decay ----

func TestDwellByAuthorCappedAndDecayed(t *testing.T) {
	db := newPersonalizationTestDB(t)
	now := time.Now()

	// 帖子 1：作者 1。插入一条 dwell=600s（超 cap）的打开记录。
	personalizationPost(t, db, 1, 1, "campus_life", now.Add(-time.Hour))
	require.NoError(t, db.Create(&models.FeedImpression{
		UserID: 99, PostID: 1, FeedSessionID: "s1", FeedKind: "all",
		AlgorithmVersion: "v5", VisibleMS: 2000, DwellMS: 600 * 1000,
		OpenedAt: &now, CreatedAt: now,
	}).Error)

	svc := NewHomeFeedService(db)
	features := svc.BuildUserFeatures(context.Background(), 99, []uint{1}, now)
	// 单次 dwell 被 cap 到 120s，且按 decay(0h)=1 计算。
	require.Equal(t, float64(maxDwellPerEventMS), features.DwellByAuthorMS[1])
}

func TestDwellDecayOverTime(t *testing.T) {
	db := newPersonalizationTestDB(t)
	now := time.Now()

	personalizationPost(t, db, 1, 1, "campus_life", now.Add(-time.Hour))
	// 5 天前的 dwell 记录（decay=0.95^5≈0.774）。
	old := now.Add(-5 * 24 * time.Hour)
	require.NoError(t, db.Create(&models.FeedImpression{
		UserID: 99, PostID: 1, FeedSessionID: "s1", FeedKind: "all",
		AlgorithmVersion: "v5", VisibleMS: 2000, DwellMS: 60 * 1000,
		OpenedAt: &old, CreatedAt: old,
	}).Error)

	svc := NewHomeFeedService(db)
	features := svc.BuildUserFeatures(context.Background(), 99, []uint{1}, now)
	want := float64(60*1000) * math.Pow(0.95, 5)
	require.InDelta(t, want, features.DwellByAuthorMS[1], 1.0)
}

// ---- reply_like → section 信号 ----

func TestReplyLikedSectionCount(t *testing.T) {
	db := newPersonalizationTestDB(t)
	now := time.Now()

	personalizationPost(t, db, 1, 1, "dining", now.Add(-time.Hour))
	personalizationPost(t, db, 2, 2, "dorm_life", now.Add(-time.Hour))
	// 用户 99 在帖 1 的评论（作者 5）上点了赞，在帖 2 的评论（作者 6）上也点了赞。
	reply1 := models.Reply{PostID: 1, AuthorID: 5, Content: "x", Status: models.ReplyStatusNormal, CreatedAt: now}
	reply2 := models.Reply{PostID: 2, AuthorID: 6, Content: "y", Status: models.ReplyStatusNormal, CreatedAt: now}
	require.NoError(t, db.Create(&reply1).Error)
	require.NoError(t, db.Create(&reply2).Error)
	require.NoError(t, db.Create(&models.Like{UserID: 99, TargetType: "reply", TargetID: reply1.ID}).Error)
	require.NoError(t, db.Create(&models.Like{UserID: 99, TargetType: "reply", TargetID: reply2.ID}).Error)

	svc := NewHomeFeedService(db)
	features := svc.BuildUserFeatures(context.Background(), 99, nil, now)
	require.True(t, features.ReplyLikedSectionCount["dining"] > 0)
	require.True(t, features.ReplyLikedSectionCount["dorm_life"] > 0)
	require.True(t, features.HasSignal)
	// reply_like 是版块信号，不累计作者。
	require.Equal(t, 0.0, features.LikedAuthorCount[5])
}

func TestRepliedSectionCount(t *testing.T) {
	db := newPersonalizationTestDB(t)
	now := time.Now()

	personalizationPost(t, db, 1, 1, "course_study", now.Add(-time.Hour))
	require.NoError(t, db.Create(&models.Reply{
		PostID: 1, AuthorID: 99, Content: "我在学习版块回复过", Status: models.ReplyStatusNormal, CreatedAt: now,
	}).Error)

	svc := NewHomeFeedService(db)
	features := svc.BuildUserFeatures(context.Background(), 99, nil, now)
	require.True(t, features.RepliedSectionCount["course_study"] > 0)
	require.True(t, features.RepliedAuthorCount[1] > 0)
}

// ---- SectionAffinity 纳入 reply_like ----

func TestSectionAffinityIncludesReplyLike(t *testing.T) {
	features := UserFeedFeatures{
		ReplyLikedSectionCount: map[string]float64{"dining": 5},
		HasSignal:              true,
	}
	score := features.SectionAffinity("dining")
	require.True(t, score > 0, "评论点赞应提升版块亲和")
	require.LessOrEqual(t, score, 1.0)
}

// ---- V5 quality 去 raw view ----

func TestScoreHomeFeedCandidateV5IgnoresViewCount(t *testing.T) {
	now := time.Now()
	highView := HomeFeedCandidate{Post: models.Post{ID: 1, LikeCount: 5, ViewCount: 100000, CreatedAt: now, LastActivityAt: now}}
	lowView := HomeFeedCandidate{Post: models.Post{ID: 2, LikeCount: 5, ViewCount: 10, CreatedAt: now, LastActivityAt: now}}
	ScoreHomeFeedCandidateV5(&highView, now)
	ScoreHomeFeedCandidateV5(&lowView, now)
	require.Equal(t, highView.Quality, lowView.Quality, "V5 质量分不得依赖 view_count")
	require.Equal(t, highView.HotScore, lowView.HotScore)
}

func TestScoreHomeFeedCandidateV4StillUsesView(t *testing.T) {
	now := time.Now()
	highView := HomeFeedCandidate{Post: models.Post{ID: 1, LikeCount: 5, ViewCount: 100000, CreatedAt: now, LastActivityAt: now}}
	lowView := HomeFeedCandidate{Post: models.Post{ID: 2, LikeCount: 5, ViewCount: 10, CreatedAt: now, LastActivityAt: now}}
	ScoreHomeFeedCandidate(&highView, now)
	ScoreHomeFeedCandidate(&lowView, now)
	require.True(t, highView.Quality > lowView.Quality, "V4 保留 raw view 奖励（兼容基线）")
}

// ---- V5 版本标识 ----

func TestPersonalizationAlgorithmVersionV5(t *testing.T) {
	require.Equal(t, "home_all_v5_personalized", personalizationAlgorithmVersionV5())
	require.Equal(t, "home_all_v4_personalized", personalizationAlgorithmVersion())
}

// ---- BuildSnapshot V5 shadow/rollout ----

func TestBuildSnapshotV5ShadowAndRollout(t *testing.T) {
	db := newPersonalizationTestDB(t)
	now := time.Now()
	for i := uint(1); i <= 4; i++ {
		personalizationPost(t, db, i, 1, "course_study", now.Add(-time.Duration(i)*time.Minute))
	}

	svc := NewHomeFeedServiceWithPoll(db)

	// V5 shadow 关 + rollout 0 → baseline。
	svc.SetPersonalizationV5(false, 0)
	base, err := svc.BuildSnapshot(context.Background(), now, 101)
	require.NoError(t, err)
	require.NotEmpty(t, base)

	// V5 shadow 开 + rollout 100 → V5 结果（同样有效排序，无重复）。
	svc.SetPersonalizationV5(true, 100)
	ids, err := svc.BuildSnapshot(context.Background(), now, 101)
	require.NoError(t, err)
	require.NotEmpty(t, ids)
	seen := map[uint]bool{}
	for _, id := range ids {
		require.False(t, seen[id], "V5 snapshot 不得出现重复帖子")
		seen[id] = true
	}
}

// ---- 指标：post_likes / reply_likes 分开 ----

func TestMetricsSeparatesPostAndReplyLikes(t *testing.T) {
	db := newMetricsTestDB(t)
	now := time.Now()

	// post like + reply like 各 1 条。
	require.NoError(t, db.Create(&models.Like{UserID: 1, TargetType: "post", TargetID: 1, CreatedAt: now}).Error)
	require.NoError(t, db.Create(&models.Like{UserID: 2, TargetType: "reply", TargetID: 1, CreatedAt: now}).Error)
	// 无曝光也保留 all 行（互动计数可参考）。
	svc := NewFeedMetricsService(db)
	require.NoError(t, svc.AggregateDay(context.Background(), now))

	var row models.FeedDailyMetrics
	require.NoError(t, db.Where("feed_kind = ?", "all").First(&row).Error)
	require.Equal(t, 1, row.Likes, "likes 仍为 post like 总数（向后兼容）")
	require.Equal(t, 1, row.PostLikes)
	require.Equal(t, 1, row.ReplyLikes)
}
