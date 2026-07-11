package services

import (
	"testing"
	"time"

	"shenliyuan/internal/models"
)

func TestRankHomeFeedKeepsFreshPostsAndCapsAuthor(t *testing.T) {
	now := time.Date(2026, 7, 11, 10, 0, 0, 0, time.UTC)
	candidates := make([]HomeFeedCandidate, 0, 33)
	for i := 0; i < 18; i++ {
		candidates = append(candidates, HomeFeedCandidate{Post: models.Post{ID: uint(i + 1), AuthorID: 1, PostType: "campus_life", CreatedAt: now.Add(-time.Duration(i+3) * time.Hour), LastActivityAt: now, LikeCount: 100}})
	}
	for i := 0; i < 15; i++ {
		candidates = append(candidates, HomeFeedCandidate{Post: models.Post{ID: uint(100 + i), AuthorID: uint(i + 2), PostType: string(rune('a' + i)), CreatedAt: now.Add(-time.Duration(i+1) * time.Hour), LastActivityAt: now}})
	}
	ids := RankHomeFeed(candidates, now)
	if len(ids) != 33 {
		t.Fatalf("ranked IDs=%d, want 33", len(ids))
	}
	firstTenAuthorOne := 0
	for _, id := range ids[:10] {
		if id <= 18 {
			firstTenAuthorOne++
		}
	}
	if firstTenAuthorOne > 2 {
		t.Fatalf("author appeared %d times in first ten", firstTenAuthorOne)
	}
	freshFound := false
	for _, id := range ids[:20] {
		if id >= 100 {
			freshFound = true
		}
	}
	if !freshFound {
		t.Fatal("fresh zero-interaction posts should receive a first-page slot")
	}
}

func TestRankHomeFeedByFreshOrder(t *testing.T) {
	now := time.Date(2026, 7, 11, 10, 0, 0, 0, time.UTC)
	candidates := make([]HomeFeedCandidate, 0, 5)
	
	for i := 0; i < 5; i++ {
		candidates = append(candidates, HomeFeedCandidate{
			Post: models.Post{
				ID: uint(i + 1),
				AuthorID: uint(i + 10),
				PostType: "campus_life",
				CreatedAt: now.Add(-time.Duration(i) * time.Hour), // i=0 is newest, i=4 is oldest
			},
		})
	}
	
	ids := RankHomeFeed(candidates, now)
	if len(ids) != 5 {
		t.Fatalf("Expected 5 items returned, got %d", len(ids))
	}
	if ids[0] != 1 || ids[1] != 2 || ids[2] != 3 {
		t.Fatalf("Expected newest posts first, got %v", ids)
	}
}

func TestRankHomeFeedRelaxationStages(t *testing.T) {
	now := time.Date(2026, 7, 11, 10, 0, 0, 0, time.UTC)
	candidates := make([]HomeFeedCandidate, 0, 40)
	
	// Create 40 posts from 10 different authors.
	for i := 0; i < 40; i++ {
		candidates = append(candidates, HomeFeedCandidate{
			Post: models.Post{
				ID: uint(i + 1),
				AuthorID: uint((i % 10) + 1), // Authors 1 to 10
				PostType: "campus_life",
				CreatedAt: now.Add(-time.Duration(i) * time.Hour),
				LastActivityAt: now,
			},
			HotScore: float64(100 - i),
		})
	}
	
	ids := RankHomeFeed(candidates, now)
	
	if len(ids) != 40 {
		t.Fatalf("Expected 40 items returned, got %d", len(ids))
	}

	authorCountsFirst10 := make(map[uint]int)
	authorCountsTotal := make(map[uint]int)
	for idx, id := range ids {
		authorID := uint(((id - 1) % 10) + 1)
		if idx < 10 {
			authorCountsFirst10[authorID]++
		}
		if idx < 20 {
			authorCountsTotal[authorID]++
		}
	}
	for author, count := range authorCountsFirst10 {
		if count > 2 {
			t.Fatalf("Author %d appeared %d times in first 10, should be <= 2", author, count)
		}
	}
	for author, count := range authorCountsTotal {
		if count > 4 {
			t.Fatalf("Author %d appeared %d times in first 20, should be <= 4", author, count)
		}
	}
}

func TestRankHomeFeedRecentThirtyDayFallbackAddsPosts(t *testing.T) {
	now := time.Date(2026, 7, 11, 10, 0, 0, 0, time.UTC)
	candidates := make([]HomeFeedCandidate, 0)
	// We add 20 very hot posts from the SAME author, so only 4 will be selected by stage 1&2
	for i := 0; i < 20; i++ {
		candidates = append(candidates, HomeFeedCandidate{
			Post: models.Post{
				ID: uint(i + 1), AuthorID: 1, PostType: "campus_life",
				CreatedAt: now.Add(-time.Hour),
				LastActivityAt: now,
				LikeCount: 1000,
			},
		})
	}
	// And we add 20 posts from different authors that are older than 7 days but within 30 days
	// so they are NOT in primary pool, they are in recent30NormalPool.
	for i := 0; i < 20; i++ {
		candidates = append(candidates, HomeFeedCandidate{
			Post: models.Post{
				ID: uint(100 + i), AuthorID: uint(100 + i), PostType: "campus_life",
				CreatedAt: now.Add(-10 * 24 * time.Hour), // 10 days old, normal post
				LastActivityAt: now.Add(-10 * 24 * time.Hour),
				LikeCount: 10,
			},
		})
	}
	ids := RankHomeFeed(candidates, now)
	// If fallback works, we should get 4 from author 1, and 16 from recent30NormalPool => 20 posts
	if len(ids) < 20 {
		t.Fatalf("Expected fallback to fill 20 spots, got %d", len(ids))
	}
	hasRecent30 := false
	for _, id := range ids[:20] {
		if id >= 100 {
			hasRecent30 = true
			break
		}
	}
	if !hasRecent30 {
		t.Fatalf("Expected recent 30-day posts in the first 20")
	}
}

func TestRankHomeFeedOldPostLimitRemainsTwo(t *testing.T) {
	now := time.Date(2026, 7, 11, 10, 0, 0, 0, time.UTC)
	candidates := make([]HomeFeedCandidate, 0)
	// Add 5 old posts > 14 days
	for i := 0; i < 5; i++ {
		candidates = append(candidates, HomeFeedCandidate{
			Post: models.Post{
				ID: uint(i + 1), AuthorID: uint(i + 10), PostType: "campus_life",
				CreatedAt: now.Add(-20 * 24 * time.Hour), // 20 days old
				LastActivityAt: now.Add(-20 * 24 * time.Hour),
				LikeCount: 1000, // Make them hot so they would be picked
			},
		})
	}
	// Add some fresh posts so we have enough
	for i := 0; i < 20; i++ {
		candidates = append(candidates, HomeFeedCandidate{
			Post: models.Post{
				ID: uint(100 + i), AuthorID: uint(100 + i), PostType: "campus_life",
				CreatedAt: now.Add(-time.Hour),
				LastActivityAt: now,
				LikeCount: 10,
			},
		})
	}
	ids := RankHomeFeed(candidates, now)
	oldPostCount := 0
	for _, id := range ids[:20] {
		if id <= 5 {
			oldPostCount++
		}
	}
	if oldPostCount > 2 {
		t.Fatalf("Expected max 2 old posts in first page, got %d", oldPostCount)
	}
}

func TestRankHomeFeedDormantOldPostNeverEntersFirstTen(t *testing.T) {
	now := time.Date(2026, 7, 11, 10, 0, 0, 0, time.UTC)
	candidates := make([]HomeFeedCandidate, 0)
	// 5 very hot old posts > 14 days
	for i := 0; i < 5; i++ {
		candidates = append(candidates, HomeFeedCandidate{
			Post: models.Post{
				ID: uint(i + 1), AuthorID: uint(i + 10), PostType: "campus_life",
				CreatedAt: now.Add(-20 * 24 * time.Hour),
				LastActivityAt: now.Add(-20 * 24 * time.Hour),
				LikeCount: 10000,
			},
		})
	}
	// 10 new posts with lower score
	for i := 0; i < 10; i++ {
		candidates = append(candidates, HomeFeedCandidate{
			Post: models.Post{
				ID: uint(100 + i), AuthorID: uint(100 + i), PostType: "campus_life",
				CreatedAt: now.Add(-time.Hour),
				LastActivityAt: now,
				LikeCount: 10,
			},
		})
	}
	ids := RankHomeFeed(candidates, now)
	// Check first 10
	for i, id := range ids {
		if i < 10 && id <= 5 {
			t.Fatalf("Old dormant post %d entered first 10 at index %d", id, i)
		}
	}
}

func TestRankHomeFeedFinalFillPreservesConstraints(t *testing.T) {
	now := time.Date(2026, 7, 11, 10, 0, 0, 0, time.UTC)
	candidates := make([]HomeFeedCandidate, 0)
	
	// Create 30 posts from the EXACT same author and same section.
	for i := 0; i < 30; i++ {
		candidates = append(candidates, HomeFeedCandidate{
			Post: models.Post{
				ID: uint(i + 1),
				AuthorID: 999, // Same author
				PostType: "campus_life", // Same section
				CreatedAt: now.Add(-time.Duration(i) * time.Minute),
				LastActivityAt: now,
				LikeCount: 1000 - i, // Very hot
			},
		})
	}
	
	ids := RankHomeFeed(candidates, now)
	
	if len(ids) != 30 {
		t.Fatalf("Expected 30 items returned total, got %d", len(ids))
	}
	
	if ids[0] != 1 {
		t.Fatalf("Expected hottest post first")
	}
}
