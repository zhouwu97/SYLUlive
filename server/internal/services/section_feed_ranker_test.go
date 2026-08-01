package services

import (
	"testing"
	"time"

	"shenliyuan/internal/models"
)

func TestRankSectionFeedCapsDormantPosts(t *testing.T) {
	now := time.Date(2026, 8, 1, 10, 0, 0, 0, time.UTC)
	candidates := make([]HomeFeedCandidate, 0, 24)
	for i := 0; i < 20; i++ {
		createdAt := now.Add(-time.Duration(i%6) * 24 * time.Hour)
		candidates = append(candidates, HomeFeedCandidate{Post: models.Post{
			ID:             uint(100 + i),
			AuthorID:       uint(100 + i),
			PostType:       "campus_life",
			CreatedAt:      createdAt,
			LastActivityAt: createdAt,
			LikeCount:      20,
		}})
	}
	for i := 0; i < 4; i++ {
		createdAt := now.Add(-20 * 24 * time.Hour)
		candidates = append(candidates, HomeFeedCandidate{Post: models.Post{
			ID:             uint(i + 1),
			AuthorID:       uint(i + 1),
			PostType:       "campus_life",
			CreatedAt:      createdAt,
			LastActivityAt: createdAt,
			LikeCount:      1000,
		}})
	}

	ids := RankSectionFeed(candidates, now, nil)
	if len(ids) < 20 {
		t.Fatalf("expected at least 20 ranked posts, got %d", len(ids))
	}
	firstTenDormant := countDormantIDs(ids[:10])
	firstTwentyDormant := countDormantIDs(ids[:20])
	if firstTenDormant > 1 {
		t.Fatalf("expected at most 1 dormant post in first 10, got %d", firstTenDormant)
	}
	if firstTwentyDormant > 2 {
		t.Fatalf("expected at most 2 dormant posts in first 20, got %d", firstTwentyDormant)
	}
}

func TestRankSectionFeedDoesNotApplySectionDiversityCap(t *testing.T) {
	now := time.Date(2026, 8, 1, 10, 0, 0, 0, time.UTC)
	candidates := make([]HomeFeedCandidate, 0, 20)
	for i := 0; i < 20; i++ {
		createdAt := now.Add(-time.Duration(i%5) * 24 * time.Hour)
		candidates = append(candidates, HomeFeedCandidate{Post: models.Post{
			ID:             uint(i + 1),
			AuthorID:       uint(i + 1),
			PostType:       "campus_life",
			CreatedAt:      createdAt,
			LastActivityAt: createdAt,
		}})
	}

	ids := RankSectionFeed(candidates, now, nil)
	if len(ids) != len(candidates) {
		t.Fatalf("expected all section candidates to remain in the feed, got %d of %d", len(ids), len(candidates))
	}
}

func TestRankSectionFeedKeepsPinnedPostsFirst(t *testing.T) {
	now := time.Date(2026, 8, 1, 10, 0, 0, 0, time.UTC)
	candidates := []HomeFeedCandidate{
		{Post: models.Post{ID: 1, AuthorID: 1, CreatedAt: now.Add(-20 * 24 * time.Hour), LastActivityAt: now.Add(-20 * 24 * time.Hour)}},
		{Post: models.Post{ID: 2, AuthorID: 2, CreatedAt: now.Add(-1 * time.Hour), LastActivityAt: now.Add(-1 * time.Hour)}},
	}

	ids := RankSectionFeed(candidates, now, map[uint]int{1: 100})
	if len(ids) < 2 || ids[0] != 1 {
		t.Fatalf("expected pinned post first, got %v", ids)
	}
}

func countDormantIDs(ids []uint) int {
	count := 0
	for _, id := range ids {
		if id <= 4 {
			count++
		}
	}
	return count
}
