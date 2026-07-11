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
