package services

import (
	"testing"
	"time"

	"shenliyuan/internal/models"
)

func TestComputeVisitOverall(t *testing.T) {
	got := ComputeVisitOverall(VisitScores{Taste: 5, Value: 4, Queue: 3, Hygiene: 4, Service: 4})
	if got != 4.2 {
		t.Fatalf("overall=%v want 4.2", got)
	}
}

func TestComputeEffectiveUserRatingUsesRecentThree(t *testing.T) {
	now := time.Now()
	newEvent := func(id uint, score int, at time.Time) models.CanteenReviewEvent {
		return models.CanteenReviewEvent{
			ID: id, TasteScore: score, ValueScore: score, QueueScore: score,
			HygieneScore: score, ServiceScore: score, OverallScore: float64(score),
			Status: models.ReviewEventStatusActive, CreatedAt: at,
		}
	}
	got := ComputeEffectiveUserRating([]models.CanteenReviewEvent{
		newEvent(1, 3, now.Add(-3*time.Hour)),
		newEvent(2, 4, now.Add(-2*time.Hour)),
		newEvent(3, 5, now.Add(-time.Hour)),
		newEvent(4, 1, now.Add(-4*time.Hour)),
	})
	if got.Overall < 4.499999 || got.Overall > 4.500001 || got.TotalEventCount != 4 || got.UsedEventCount != 3 || got.LatestEventID != 3 {
		t.Fatalf("result=%+v want overall=4.5 total=4 used=3 latest=3", got)
	}
}

func TestComputeEffectiveUserRatingExcludesLegacyEventFromDimensionScore(t *testing.T) {
	now := time.Now()
	legacy := models.CanteenReviewEvent{
		ID: 1, OverallScore: 5, ScoreVersion: 1, Status: models.ReviewEventStatusActive,
		CreatedAt: now.Add(-time.Hour),
	}
	v2 := models.CanteenReviewEvent{
		ID: 2, TasteScore: 2, ValueScore: 2, QueueScore: 2, HygieneScore: 2, ServiceScore: 2,
		OverallScore: 2, ScoreVersion: 2, Status: models.ReviewEventStatusActive,
		CreatedAt: now,
	}
	got := ComputeEffectiveUserRating([]models.CanteenReviewEvent{legacy, v2})
	if got.TotalEventCount != 2 || got.UsedEventCount != 1 || got.Overall != 2 || got.Taste != 2 {
		t.Fatalf("legacy event polluted effective score: %+v", got)
	}
}

func TestComputeCreditWeightRange(t *testing.T) {
	if got := ComputeCreditWeight(0); got != 0.5 {
		t.Fatalf("credit 0 weight=%v", got)
	}
	if got := ComputeCreditWeight(100); got != 1 {
		t.Fatalf("credit 100 weight=%v", got)
	}
}

func TestComputeCanteenAggregateWeighted(t *testing.T) {
	got := ComputeCanteenAggregate([]UserRatingSample{{Overall: 5, Weight: 1}, {Overall: 1, Weight: 0.5}})
	if got.AverageScore != 3.6666666666666665 || got.ReviewerCount != 2 {
		t.Fatalf("aggregate=%+v", got)
	}
}

func TestComputeCanteenAggregateDoesNotUseLegacyZeroDimensions(t *testing.T) {
	got := ComputeCanteenAggregate([]UserRatingSample{
		{Overall: 5, Taste: 5, Weight: 1, HasDimensions: true},
		{Overall: 4, Weight: 1, HasDimensions: false},
	})
	if got.AverageScore != 4.5 || got.TasteScore != 5 || got.DimensionEffectiveSample != 1 {
		t.Fatalf("legacy sample polluted dimensions: %+v", got)
	}
}

func TestComputeDishAggregateDoesNotUseStoreDimensions(t *testing.T) {
	got := ComputeDishAggregate([]DishRatingSample{{Taste: 5, Value: 4, Portion: 3, Overall: 4.2, Weight: 1}})
	if got.AverageScore != 4.2 || got.PortionScore != 3 {
		t.Fatalf("aggregate=%+v", got)
	}
}
