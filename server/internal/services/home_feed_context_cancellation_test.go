package services

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
)

func TestHomeFeedServiceContextCancellation(t *testing.T) {
	db := newPersonalizationTestDB(t)
	now := time.Now()

	// Seed posts
	post1 := personalizationPost(t, db, 1, 10, "course_study", now.Add(-1*time.Hour))
	post2 := personalizationPost(t, db, 2, 20, "campus_life", now.Add(-2*time.Hour))
	_ = post1
	_ = post2

	// Seed pinned post
	pinnedPost := models.Post{
		ID:           3,
		BoardID:      models.BoardShuitie,
		AuthorID:     30,
		PostType:     "campus_life",
		Title:        "置顶帖",
		Content:      "置顶内容",
		Status:       models.PostStatusNormal,
		IsPinned:     true,
		PinnedAt:     &now,
		PinnedWeight: 10,
		CreatedAt:    now.Add(-30 * time.Minute),
	}
	require.NoError(t, db.Create(&pinnedPost).Error)

	svc := NewHomeFeedService(db)

	t.Run("PinnedPosts returns error when context is already cancelled", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // Cancel immediately

		posts, err := svc.PinnedPosts(ctx, now)
		require.Error(t, err, "PinnedPosts should return an error when context is cancelled")
		require.Nil(t, posts, "PinnedPosts should return nil posts on cancelled context")
	})

	t.Run("BuildSnapshot returns error when context is already cancelled", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // Cancel immediately

		ids, err := svc.BuildSnapshot(ctx, now, 10)
		require.Error(t, err, "BuildSnapshot should return an error when context is cancelled")
		require.Nil(t, ids, "BuildSnapshot should return nil ids on cancelled context")
	})

	t.Run("PinnedPosts succeeds with active context", func(t *testing.T) {
		ctx := context.Background()
		posts, err := svc.PinnedPosts(ctx, now)
		require.NoError(t, err)
		require.NotEmpty(t, posts)
		require.Equal(t, uint(3), posts[0].ID)
	})

	t.Run("BuildSnapshot succeeds with active context", func(t *testing.T) {
		ctx := context.Background()
		ids, err := svc.BuildSnapshot(ctx, now, 10)
		require.NoError(t, err)
		require.NotEmpty(t, ids)
	})
}
