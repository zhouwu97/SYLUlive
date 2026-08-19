package handlers

import (
	"database/sql/driver"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	gosqlite "github.com/glebarez/go-sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// init 时给 SQLite 测试驱动注册 GREATEST（like.go 生产 SQL 依赖，
// PostgreSQL 原生支持；SQLite 测试驱动需要手动注册）。
func init() {
	gosqlite.MustRegisterScalarFunction("GREATEST", -1, func(
		ctx *gosqlite.FunctionContext,
		args []driver.Value,
	) (driver.Value, error) {
		var max driver.Value
		for _, a := range args {
			if max == nil || compareDriverValues(a, max) > 0 {
				max = a
			}
		}
		return max, nil
	})
}

// 防止 init 注册被误删的哨兵。
var _ = sync.Once{}

// compareDriverValues 比较 int64/float64 数值。
func compareDriverValues(a, b driver.Value) int {
	af, aok := toFloat(a)
	bf, bok := toFloat(b)
	if aok && bok {
		if af > bf {
			return 1
		}
		if af < bf {
			return -1
		}
		return 0
	}
	as, aok2 := a.(string)
	bs, bok2 := b.(string)
	if aok2 && bok2 {
		if as > bs {
			return 1
		}
		if as < bs {
			return -1
		}
	}
	return 0
}

func toFloat(v driver.Value) (float64, bool) {
	switch n := v.(type) {
	case int64:
		return float64(n), true
	case float64:
		return n, true
	case int:
		return float64(n), true
	}
	return 0, false
}

// performLikeRequest 请求 POST/DELETE /api/replies/:id/like。
func performLikeRequest(t *testing.T, db *gorm.DB, replyID uint, like bool, userID uint) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	method := http.MethodDelete
	if like {
		method = http.MethodPost
	}
	context.Request = httptest.NewRequest(method, fmt.Sprintf("/api/replies/%d/like", replyID), nil)
	context.Params = gin.Params{{Key: "id", Value: fmt.Sprint(replyID)}}
	context.Set("user_id", userID)
	handler := NewLikeHandler(db)
	if like {
		handler.LikeReply(context)
	} else {
		handler.UnlikeReply(context)
	}
	return recorder
}

func likeTestFixture(t *testing.T, db *gorm.DB) (models.Post, models.Reply, models.User) {
	t.Helper()
	createMessageTestUser(t, db, 1, "作者")
	createMessageTestUser(t, db, 2, "点赞者")
	now := time.Now()
	post := models.Post{
		Title: "点赞测试帖", Content: "正文", BoardID: models.BoardShuitie,
		AuthorID: 1, ContentKind: models.PostContentKindNormal,
		Status: models.PostStatusNormal, CreatedAt: now, LastActivityAt: now,
	}
	require.NoError(t, db.Create(&post).Error)
	reply := models.Reply{PostID: post.ID, AuthorID: 1, Content: "评论", Status: models.ReplyStatusNormal, CreatedAt: now}
	require.NoError(t, db.Create(&reply).Error)
	var author models.User
	require.NoError(t, db.First(&author, 1).Error)
	return post, reply, author
}

// 第一次 like → like row +1 → reply.like_count +1 → total_likes_received +1。
func TestLikeReplyIncrementsAllCounters(t *testing.T) {
	db := newReplyTestDB(t)
	_, reply, author := likeTestFixture(t, db)

	response := performLikeRequest(t, db, reply.ID, true, 2)
	require.Equal(t, http.StatusCreated, response.Code)

	var likeCount int64
	require.NoError(t, db.Model(&models.Like{}).Where("target_type = ? AND target_id = ?", "reply", reply.ID).Count(&likeCount).Error)
	require.EqualValues(t, 1, likeCount)

	var updatedReply models.Reply
	require.NoError(t, db.First(&updatedReply, reply.ID).Error)
	require.Equal(t, 1, updatedReply.LikeCount)

	var updatedAuthor models.User
	require.NoError(t, db.First(&updatedAuthor, author.ID).Error)
	require.Equal(t, 1, updatedAuthor.TotalLikesReceived, "reply like 计入 total_likes_received")
}

// 重复 like → 不产生第二条 Like → count 不重复增加。
func TestLikeReplyDuplicate(t *testing.T) {
	db := newReplyTestDB(t)
	_, reply, author := likeTestFixture(t, db)

	require.Equal(t, http.StatusCreated, performLikeRequest(t, db, reply.ID, true, 2).Code)
	// 重复点赞：OnConflict DoNothing → 200，不新增。
	require.Equal(t, http.StatusOK, performLikeRequest(t, db, reply.ID, true, 2).Code)

	var likeCount int64
	require.NoError(t, db.Model(&models.Like{}).Where("target_type = ? AND target_id = ?", "reply", reply.ID).Count(&likeCount).Error)
	require.EqualValues(t, 1, likeCount)

	var updatedReply models.Reply
	require.NoError(t, db.First(&updatedReply, reply.ID).Error)
	require.Equal(t, 1, updatedReply.LikeCount)

	var updatedAuthor models.User
	require.NoError(t, db.First(&updatedAuthor, author.ID).Error)
	require.Equal(t, 1, updatedAuthor.TotalLikesReceived)
}

// unlike → 删除 Like → count -1 → total_likes_received -1。
func TestUnlikeReplyDecrements(t *testing.T) {
	db := newReplyTestDB(t)
	_, reply, author := likeTestFixture(t, db)

	performLikeRequest(t, db, reply.ID, true, 2)
	require.Equal(t, http.StatusOK, performLikeRequest(t, db, reply.ID, false, 2).Code)

	var likeCount int64
	require.NoError(t, db.Model(&models.Like{}).Where("target_type = ? AND target_id = ?", "reply", reply.ID).Count(&likeCount).Error)
	require.EqualValues(t, 0, likeCount)

	var updatedReply models.Reply
	require.NoError(t, db.First(&updatedReply, reply.ID).Error)
	require.Equal(t, 0, updatedReply.LikeCount)

	var updatedAuthor models.User
	require.NoError(t, db.First(&updatedAuthor, author.ID).Error)
	require.Equal(t, 0, updatedAuthor.TotalLikesReceived)
}

// 重复 unlike → count 不低于 0。
func TestUnlikeReplyFloorAtZero(t *testing.T) {
	db := newReplyTestDB(t)
	_, reply, author := likeTestFixture(t, db)

	// 从未点赞就取消 → 200，count 保持 0。
	require.Equal(t, http.StatusOK, performLikeRequest(t, db, reply.ID, false, 2).Code)
	var updatedReply models.Reply
	require.NoError(t, db.First(&updatedReply, reply.ID).Error)
	require.Equal(t, 0, updatedReply.LikeCount)
	var updatedAuthor models.User
	require.NoError(t, db.First(&updatedAuthor, author.ID).Error)
	require.Equal(t, 0, updatedAuthor.TotalLikesReceived)
}

// deleted reply → 禁止 like（409）。
func TestLikeReplyDeletedReplyRejected(t *testing.T) {
	db := newReplyTestDB(t)
	_, reply, _ := likeTestFixture(t, db)
	require.NoError(t, db.Model(&reply).Update("status", models.ReplyStatusDeleted).Error)

	response := performLikeRequest(t, db, reply.ID, true, 2)
	require.Equal(t, http.StatusConflict, response.Code)
}

// deleted / non-normal post → 禁止 like（409）。
func TestLikeReplyDeletedPostRejected(t *testing.T) {
	db := newReplyTestDB(t)
	post, reply, _ := likeTestFixture(t, db)
	require.NoError(t, db.Model(&post).Update("status", models.PostStatusDeleted).Error)

	response := performLikeRequest(t, db, reply.ID, true, 2)
	require.Equal(t, http.StatusConflict, response.Code)
}

// gormDB 是 *gorm.DB 的便捷别名（shared-cache memory DB 需要并发共享连接）。
type gormDB = gorm.DB

// newSharedReplyTestDB 使用 shared-cache 内存库，供并发测试跨连接共享同一库。
func newSharedReplyTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:likereply_shared?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.Post{},
		&models.Reply{},
		&models.ReplyImage{},
		&models.File{},
		&models.FileUploadGrant{},
		&models.ExpLog{},
		&models.Notification{},
		&models.Like{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

// 并发两个 LikeReply：唯一约束仍是最终防线。
func TestLikeReplyConcurrentUnique(t *testing.T) {
	db := newSharedReplyTestDB(t)
	_, reply, _ := likeTestFixture(t, db)

	done := make(chan int, 2)
	for i := 0; i < 2; i++ {
		go func() {
			response := performLikeRequest(t, db, reply.ID, true, 2)
			done <- response.Code
		}()
	}
	codes := []int{<-done, <-done}
	// 一个 Created（201）、一个重复（200），不可能出现两条 Like。
	created, dup := 0, 0
	for _, code := range codes {
		if code == http.StatusCreated {
			created++
		} else if code == http.StatusOK {
			dup++
		}
	}
	require.Equal(t, 1, created, "并发点赞只能成功一次，got %v", codes)
	require.Equal(t, 1, dup)

	var likeCount int64
	require.NoError(t, db.Model(&models.Like{}).Where("target_type = ? AND target_id = ?", "reply", reply.ID).Count(&likeCount).Error)
	require.EqualValues(t, 1, likeCount)
}
