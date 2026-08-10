package services

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

var personalizationTestDBSeq int64

func newPersonalizationTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	seq := atomic.AddInt64(&personalizationTestDBSeq, 1)
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:pers_%d?mode=memory&cache=shared", seq)), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&models.Post{}, &models.Like{}, &models.Reply{}, &models.FeedImpression{},
		&models.UserFollow{}, &models.WaterSectionFollow{}, &models.WaterSection{},
		&models.UserHiddenAuthor{}, &models.FeedFeedback{}, &models.WaterTeamRecruitment{},
		&models.PostImage{}, &models.File{}, &models.FeedRankTrace{}, &models.Poll{},
	))
	return db
}

func personalizationPost(t *testing.T, db *gorm.DB, id, authorID uint, postType string, created time.Time) models.Post {
	t.Helper()
	p := models.Post{ID: id, BoardID: models.BoardShuitie, AuthorID: authorID, PostType: postType,
		Title: fmt.Sprintf("帖%d", id), Content: "x", Status: models.PostStatusNormal, CreatedAt: created}
	require.NoError(t, db.Create(&p).Error)
	return p
}

func TestPersonalDeltaColdStartAndClamp(t *testing.T) {
	now := time.Now()
	c := HomeFeedCandidate{Post: models.Post{ID: 1, AuthorID: 1, PostType: "course_study", CreatedAt: now}}

	// 冷启动：无信号 → 0。
	empty := UserFeedFeatures{UserID: 1}
	require.Equal(t, 0.0, ComputePersonalDelta(c, empty, now))

	// 强信号 + 关注作者 48h 新帖 → 正向，但 clamp 到 0.20。
	feat := UserFeedFeatures{
		UserID:             1,
		FollowedAuthors:    map[uint]bool{1: true},
		RepliedAuthorCount: map[uint]float64{1: 5},
		LikedAuthorCount:   map[uint]float64{1: 3},
		OpenedAuthorCount:  map[uint]float64{1: 2},
		LikedSectionCount:  map[string]float64{"course_study": 2},
		OpenedSectionCount: map[string]float64{"course_study": 1},
		HasSignal:          true,
	}
	delta := ComputePersonalDelta(c, feat, now)
	require.LessOrEqual(t, delta, 0.20)

	// 多个不同 session 曝光从未 open → 负向惩罚，clamp 到 -0.20。
	featPenalized := UserFeedFeatures{
		UserID:             1,
		SeenSessionsByPost: map[uint]int{1: 5},
		SeenOpenedPostIDs:  map[uint]bool{},
		HasSignal:          true,
	}
	deltaP := ComputePersonalDelta(c, featPenalized, now)
	require.LessOrEqual(t, deltaP, 0.0)
	require.GreaterOrEqual(t, deltaP, -0.20)
}

func TestUserInRollout(t *testing.T) {
	require.False(t, userInRollout(1, 0))
	require.True(t, userInRollout(1, 100))
	// 稳定：同一用户同百分比结果一致。
	require.Equal(t, userInRollout(42, 10), userInRollout(42, 10))
}

func TestApplyExploration(t *testing.T) {
	now := time.Now()
	var candidates []HomeFeedCandidate
	var ranked []uint
	for i := 1; i <= 30; i++ {
		p := models.Post{ID: uint(i), AuthorID: 1, PostType: "campus_life", CreatedAt: now.Add(-time.Hour * time.Duration(i))}
		candidates = append(candidates, HomeFeedCandidate{Post: p})
		ranked = append(ranked, uint(i))
	}
	features := UserFeedFeatures{HasSignal: true}
	out := applyExploration(ranked, candidates, features, now)
	require.Len(t, out, 30)
	// 槽位 4/10/16 被探索候选替换（不是原来的 5/11/17 的 id）。
	require.NotEqual(t, uint(5), out[4])
	require.NotEqual(t, uint(11), out[10])
	require.NotEqual(t, uint(17), out[16])
	// 其余槽位保持。
	require.Equal(t, uint(1), out[0])
	require.Equal(t, uint(2), out[1])
}

func TestBuildSnapshotShadowAndRollout(t *testing.T) {
	db := newPersonalizationTestDB(t)
	now := time.Now()

	// 两个作者、两个版块、6 条新帖。
	for i := uint(1); i <= 6; i++ {
		author := uint(1)
		if i > 3 {
			author = 2
		}
		ptype := "course_study"
		if i > 3 {
			ptype = "campus_life"
		}
		personalizationPost(t, db, i, author, ptype, now.Add(-time.Duration(i)*time.Minute))
	}

	// 用户 A 关注作者 1（版块 course_study）；用户 B 关注作者 2（版块 campus_life）。
	require.NoError(t, db.Create(&models.UserFollow{FollowerID: 101, FollowingID: 1}).Error)
	require.NoError(t, db.Create(&models.UserFollow{FollowerID: 102, FollowingID: 2}).Error)

	svc := NewHomeFeedServiceWithPoll(db)

	// Shadow 开、percent=0 → 返回 baseline（个性化计算但用户顺序不变）。
	svc.SetPersonalization(true, 0)
	base, err := svc.BuildSnapshot(context.Background(), now, 101)
	require.NoError(t, err)
	require.NotEmpty(t, base)

	// percent=100 → 用户进 rollout，返回个性化结果（仍为有效排序）。
	svc.SetPersonalization(true, 100)
	persA, err := svc.BuildSnapshot(context.Background(), now, 101)
	require.NoError(t, err)
	persB, err := svc.BuildSnapshot(context.Background(), now, 102)
	require.NoError(t, err)
	require.NotEmpty(t, persA)
	require.NotEmpty(t, persB)

	// 兴趣不同的两个用户排序应不同（强关注信号下）。
	require.NotEqual(t, persA, persB, "不同兴趣用户应产生不同个性化排序")
}

func TestBuildSnapshotShadowOffReturnsBaseline(t *testing.T) {
	db := newPersonalizationTestDB(t)
	now := time.Now()
	for i := uint(1); i <= 4; i++ {
		personalizationPost(t, db, i, 1, "course_study", now.Add(-time.Duration(i)*time.Minute))
	}
	svc := NewHomeFeedServiceWithPoll(db)
	svc.SetPersonalization(false, 0)
	ids, err := svc.BuildSnapshot(context.Background(), now, 5)
	require.NoError(t, err)
	require.NotEmpty(t, ids)
}
