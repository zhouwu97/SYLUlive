package handlers

import (
	"testing"
	"time"

	"shenliyuan/internal/models"
)

func TestBuildCanteenDisplayReviewsKeepsSourceWhenIDsCollide(t *testing.T) {
	now := time.Now()
	v2 := models.CanteenReviewEvent{
		ID: 17, CanteenID: 1, UserID: 11, UserName: "V2同学", OverallScore: 3.5,
		Comment: "新版评价", Status: models.ReviewEventStatusActive, ScoreVersion: 2,
		CreatedAt: now,
	}
	legacy := models.CanteenRating{
		ID: 17, CanteenID: 1, UserID: 22, UserName: "旧版同学", Star: 5,
		Comment: "旧版评价", Status: models.ReviewEventStatusActive,
		CreatedAt: now.Add(-time.Hour),
	}
	items := buildCanteenDisplayReviews("一食堂", []models.CanteenReviewEvent{v2}, []models.CanteenRating{legacy}, "latest", "all")
	if len(items) != 2 {
		t.Fatalf("items=%v", items)
	}
	if items[0]["id"] != uint(17) || items[0]["source"] != "v2" || items[0]["user_id"] != uint(11) {
		t.Fatalf("v2 item=%v", items[0])
	}
	if items[1]["id"] != uint(17) || items[1]["source"] != "legacy" || items[1]["user_id"] != uint(22) {
		t.Fatalf("legacy item=%v", items[1])
	}
}

func TestBuildCanteenDisplayReviewsPrefersV2ForSameUser(t *testing.T) {
	v2 := models.CanteenReviewEvent{ID: 3, CanteenID: 1, UserID: 11, OverallScore: 4, Status: models.ReviewEventStatusActive, ScoreVersion: 2, CreatedAt: time.Now()}
	legacy := models.CanteenRating{ID: 9, CanteenID: 1, UserID: 11, Star: 5, Status: models.ReviewEventStatusActive, CreatedAt: time.Now()}
	items := buildCanteenDisplayReviews("一食堂", []models.CanteenReviewEvent{v2}, []models.CanteenRating{legacy}, "latest", "all")
	if len(items) != 1 || items[0]["source"] != "v2" {
		t.Fatalf("same user was not deduplicated: %v", items)
	}
}
