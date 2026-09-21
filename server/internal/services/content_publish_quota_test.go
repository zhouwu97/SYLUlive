package services

import (
	"errors"
	"fmt"

	"sync/atomic"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

var quotaTestSeq int64

func newQuotaTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	seq := atomic.AddInt64(&quotaTestSeq, 1)
	// 使用内存库避免 Windows 上临时文件被连接池占用导致清理失败。
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:quota_%d?mode=memory&cache=shared", seq)), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.Post{}, &models.Reply{}))
	return db
}

func seedQuotaUser(t *testing.T, db *gorm.DB) models.User {
	t.Helper()
	user := models.User{Nickname: "额度用户", PasswordHash: "x"}
	require.NoError(t, db.Create(&user).Error)
	return user
}

func seedQuotaPost(t *testing.T, db *gorm.DB, userID uint, createdAt time.Time) models.Post {
	t.Helper()
	post := models.Post{
		Title: "t", Content: "c", BoardID: models.BoardShuitie, AuthorID: userID,
		Status: models.PostStatusNormal, CreatedAt: createdAt, LastActivityAt: createdAt,
	}
	require.NoError(t, db.Create(&post).Error)
	return post
}

func seedQuotaReply(t *testing.T, db *gorm.DB, userID, postID uint, content string, createdAt time.Time) models.Reply {
	t.Helper()
	reply := models.Reply{
		PostID: postID, AuthorID: userID, Content: content,
		Status: models.ReplyStatusNormal, CreatedAt: createdAt,
	}
	require.NoError(t, db.Create(&reply).Error)
	return reply
}

// RATE-01：固定时钟下的窗口边界——第 N 条成功、第 N+1 条被拒、窗口到期后恢复。
func TestPostPublishQuotaWindowBoundary(t *testing.T) {
	db := newQuotaTestDB(t)
	user := seedQuotaUser(t, db)
	now := time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)

	// 窗口右边界闭区间：created_at == now 必须计入。
	for i := 0; i < PostPublishShortLimit; i++ {
		seedQuotaPost(t, db, user.ID, now.Add(-time.Duration(i)*time.Second))
	}
	var counted int64
	require.NoError(t, db.Model(&models.Post{}).Where("author_id = ?", user.ID).Count(&counted).Error)
	require.EqualValues(t, PostPublishShortLimit, counted)

	err := CheckPostPublishQuota(db, user.ID, now)
	require.ErrorIs(t, err, ErrContentRateLimited, "第 N+1 条必须被拒")

	// 窗口左边界开区间：刚好落在 now-window 上的记录不再占用额度。
	boundaryDB := newQuotaTestDB(t)
	boundaryUser := seedQuotaUser(t, boundaryDB)
	for i := 0; i < PostPublishShortLimit; i++ {
		seedQuotaPost(t, boundaryDB, boundaryUser.ID, now.Add(-PostPublishShortWindow))
	}
	require.NoError(t, CheckPostPublishQuota(boundaryDB, boundaryUser.ID, now),
		"刚好位于窗口起点的记录不应继续占用额度")

	// 短窗口到期（把记录整体前移超过窗口）后恢复。
	expiredDB := newQuotaTestDB(t)
	expiredUser := seedQuotaUser(t, expiredDB)
	for i := 0; i < PostPublishShortLimit; i++ {
		seedQuotaPost(t, expiredDB, expiredUser.ID, now.Add(-PostPublishShortWindow-time.Minute))
	}
	require.NoError(t, CheckPostPublishQuota(expiredDB, expiredUser.ID, now), "窗口到期后应恢复额度")

	// 长窗口独立生效：短窗口为空但 24 小时内已满 30 条。
	longDB := newQuotaTestDB(t)
	longUser := seedQuotaUser(t, longDB)
	for i := 0; i < PostPublishLongLimit; i++ {
		seedQuotaPost(t, longDB, longUser.ID, now.Add(-time.Hour))
	}
	require.ErrorIs(t, CheckPostPublishQuota(longDB, longUser.ID, now), ErrContentRateLimited,
		"滚动 24 小时额度必须独立生效")
}

// RATE-07：纯贴图/表情回复也计入时间额度；只有真实文本参与 1 分钟重复判定。
func TestReplyPublishQuotaCountsMediaAndDeduplicatesText(t *testing.T) {
	db := newQuotaTestDB(t)
	user := seedQuotaUser(t, db)
	post := seedQuotaPost(t, db, user.ID, time.Now())
	now := time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)

	// 空 content（纯贴图/表情）不参与重复判定，但依然占用时间额度。
	for i := 0; i < ReplyPublishShortLimit; i++ {
		seedQuotaReply(t, db, user.ID, post.ID, "", now.Add(-time.Duration(i)*time.Second))
	}
	require.ErrorIs(t, CheckReplyPublishQuota(db, user.ID, post.ID, "", now), ErrContentRateLimited,
		"纯贴图回复必须计入时间额度，不能因 content 为空跳过所有限流")

	// 重复文本判定：同一账号同一帖子 1 分钟内相同文本被拒，超出窗口则放行。
	dupDB := newQuotaTestDB(t)
	dupUser := seedQuotaUser(t, dupDB)
	dupPost := seedQuotaPost(t, dupDB, dupUser.ID, now)
	seedQuotaReply(t, dupDB, dupUser.ID, dupPost.ID, "同样的话", now.Add(-30*time.Second))
	require.ErrorIs(t, CheckReplyPublishQuota(dupDB, dupUser.ID, dupPost.ID, "同样的话", now), ErrContentDuplicate)
	// 与持久化一致的规范化文本：两侧空白不影响判定。
	require.ErrorIs(t, CheckReplyPublishQuota(dupDB, dupUser.ID, dupPost.ID, "  同样的话  ", now), ErrContentDuplicate)
	// 不同文本放行。
	require.NoError(t, CheckReplyPublishQuota(dupDB, dupUser.ID, dupPost.ID, "不一样的话", now))
	// 超过 1 分钟窗口放行。
	require.NoError(t, CheckReplyPublishQuota(dupDB, dupUser.ID, dupPost.ID, "同样的话", now.Add(2*time.Minute)))
	// 不同帖子放行。
	otherPost := seedQuotaPost(t, dupDB, dupUser.ID, now)
	require.NoError(t, CheckReplyPublishQuota(dupDB, dupUser.ID, otherPost.ID, "同样的话", now))
}

// RATE-06：删除/隐藏已成功发表的内容不返还发布额度。
func TestPublishQuotaNotRefundedOnDelete(t *testing.T) {
	db := newQuotaTestDB(t)
	user := seedQuotaUser(t, db)
	now := time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)

	var posts []models.Post
	for i := 0; i < PostPublishShortLimit; i++ {
		posts = append(posts, seedQuotaPost(t, db, user.ID, now.Add(-time.Duration(i)*time.Second)))
	}
	// 作者删除全部已发表内容。
	require.NoError(t, db.Model(&models.Post{}).
		Where("author_id = ?", user.ID).
		Update("status", models.PostStatusDeleted).Error)

	require.ErrorIs(t, CheckPostPublishQuota(db, user.ID, now), ErrContentRateLimited,
		"删除只是状态变更，成功发表历史仍必须在窗口内计数")

	// 治理隐藏同样不返还额度。
	hiddenDB := newQuotaTestDB(t)
	hiddenUser := seedQuotaUser(t, hiddenDB)
	for i := 0; i < PostPublishShortLimit; i++ {
		seedQuotaPost(t, hiddenDB, hiddenUser.ID, now.Add(-time.Duration(i)*time.Second))
	}
	require.NoError(t, hiddenDB.Model(&models.Post{}).
		Where("author_id = ?", hiddenUser.ID).
		Update("status", models.PostStatusModeratedHidden).Error)
	require.ErrorIs(t, CheckPostPublishQuota(hiddenDB, hiddenUser.ID, now), ErrContentRateLimited)
}

// RATE-05：Count 失败不能按 0 次处理，必须返回“额度服务暂不可用”。
func TestPublishQuotaCountFailureIsNotZero(t *testing.T) {
	db := newQuotaTestDB(t)
	user := seedQuotaUser(t, db)
	now := time.Now()

	// 让计数查询失败（表被删除）。
	require.NoError(t, db.Migrator().DropTable(&models.Post{}))
	err := CheckPostPublishQuota(db, user.ID, now)
	require.Error(t, err)
	require.ErrorIs(t, err, ErrContentQuotaUnavailable, "查询失败必须映射为 503 语义，而不是放行")
	require.False(t, errors.Is(err, ErrContentRateLimited))

	// 锁失败同样映射为暂不可用。
	lockErr := LockUserForContentWrite(db, 999999)
	require.ErrorIs(t, lockErr, ErrContentQuotaUnavailable)
	require.ErrorIs(t, LockUserForContentWrite(db, 0), ErrContentQuotaUnavailable)
}

// 不同用户之间不应互相占用额度。
func TestPublishQuotaIsolatedPerUser(t *testing.T) {
	db := newQuotaTestDB(t)
	busy := seedQuotaUser(t, db)
	idle := seedQuotaUser(t, db)
	now := time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)

	for i := 0; i < PostPublishShortLimit; i++ {
		seedQuotaPost(t, db, busy.ID, now.Add(-time.Duration(i)*time.Second))
	}
	require.ErrorIs(t, CheckPostPublishQuota(db, busy.ID, now), ErrContentRateLimited)
	require.NoError(t, CheckPostPublishQuota(db, idle.ID, now), "额度必须按账号隔离")
}
