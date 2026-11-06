package handlers

import (
	"net/http"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
)

func TestReceivedLikesPostgresConcurrentMutations(t *testing.T) {
	db := integrationLockDB(t)
	require.NoError(t, db.AutoMigrate(&models.Like{}, &models.UserFollow{}, &models.PostImage{},
		&models.PostRectificationReview{}, &models.Appeal{}))
	post, reply, _ := likeTestFixture(t, db)
	createMessageTestUser(t, db, 3, "评论作者")
	require.NoError(t, db.Model(&reply).Update("author_id", 3).Error)
	h := NewLikeHandler(db)
	// 同一点赞者并发重复请求，唯一约束必须确保仅有一条事实。
	var group sync.WaitGroup
	codes := make(chan int, 16)
	for i := 0; i < 8; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			codes <- callReceivedLikesHandler(t, h.LikePost, 2, post.ID, http.MethodPost).Code
			codes <- callReceivedLikesHandler(t, h.LikeReply, 2, reply.ID, http.MethodPost).Code
		}()
	}
	group.Wait()
	close(codes)
	for code := range codes {
		require.Contains(t, []int{http.StatusOK, http.StatusCreated}, code)
	}
	assertReceivedLikesTotal(t, db, 1, 1)
	assertReceivedLikesTotal(t, db, 3, 1)
	// 与作者删除并发的赞无论先后提交，最终均不能进入当前有效总数。
	codes = make(chan int, 10)
	start := make(chan struct{})
	for i := 0; i < 8; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			<-start
			codes <- callReceivedLikesHandler(t, h.LikePost, 2, post.ID, http.MethodPost).Code
		}()
	}
	for i := 0; i < 2; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			<-start
			codes <- callReceivedLikesHandler(t, NewPostHandler(db, "", "").Delete, 1, post.ID, http.MethodDelete).Code
		}()
	}
	close(start)
	group.Wait()
	close(codes)
	for code := range codes {
		require.Contains(t, []int{http.StatusOK, http.StatusCreated, http.StatusConflict}, code)
	}
	assertReceivedLikesTotal(t, db, 1, 0)
	assertReceivedLikesTotal(t, db, 3, 0)
	require.NoError(t, db.Model(&post).Update("status", models.PostStatusNormal).Error)
	assertReceivedLikesTotal(t, db, 1, 1)
	assertReceivedLikesTotal(t, db, 3, 1)
	// 恢复公开后并发取消，重复取消不能误扣别的有效赞。
	codes = make(chan int, 8)
	for i := 0; i < 8; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			codes <- callReceivedLikesHandler(t, h.UnlikePost, 2, post.ID, http.MethodDelete).Code
		}()
	}
	group.Wait()
	close(codes)
	for code := range codes {
		require.Equal(t, http.StatusOK, code)
	}
	assertReceivedLikesTotal(t, db, 1, 0)
	assertReceivedLikesTotal(t, db, 3, 1)
}
