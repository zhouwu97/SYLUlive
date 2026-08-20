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
	if got.Overall < 4.499999 || got.Overall > 4.500001 || got.EventCount != 3 || got.LatestEventID != 3 {
		t.Fatalf("result=%+v want overall=4.5 count=3 latest=3", got)
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

func TestComputeDishAggregateDoesNotUseStoreDimensions(t *testing.T) {
	got := ComputeDishAggregate([]DishRatingSample{{Taste: 5, Value: 4, Portion: 3, Overall: 4.2, Weight: 1}})
	if got.AverageScore != 4.2 || got.PortionScore != 3 {
		t.Fatalf("aggregate=%+v", got)
	}
}
