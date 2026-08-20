package handlers

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"shenliyuan/internal/models"
)

func prepareReviewV2DB(t *testing.T) (*CanteenHandler, models.Canteen, models.User) {
	t.Helper()
	db := newCanteenTestDB(t)
	if err := models.EnsureCanteenReviewSchema(db); err != nil {
		t.Fatalf("migrate review v2: %v", err)
	}
	verifiedAt := time.Now()
	user := models.User{ID: 88, StudentID: "student-88", PasswordHash: "test", Nickname: "评价同学", CreditScore: 80, StudentVerifiedAt: &verifiedAt}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	canteen := models.Canteen{ID: 88, Name: "一食堂", Image: "/uploads/canteen.png", CreatedBy: user.ID, Verified: true}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatalf("create canteen: %v", err)
	}
	return NewCanteenHandler(db), canteen, user
}

func reviewBody() string {
	return `{"taste_score":5,"value_score":4,"queue_score":3,"hygiene_score":4,"service_score":4,"comment":"好吃"}`
}

func TestCreateReviewKeepsEventsAndRecomputesSummary(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	first := performCanteenRequest(t, h.CreateReview, http.MethodPost,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID, reviewBody())
	if first.Code != http.StatusCreated {
		t.Fatalf("first status=%d body=%s", first.Code, first.Body.String())
	}
	var old models.CanteenReviewEvent
	if err := h.db.First(&old).Error; err != nil {
		t.Fatalf("load event: %v", err)
	}
	if err := h.db.Model(&old).Update("created_at", time.Now().Add(-7*time.Hour)).Error; err != nil {
		t.Fatalf("age event: %v", err)
	}
	second := performCanteenRequest(t, h.CreateReview, http.MethodPost,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID,
		`{"taste_score":2,"value_score":2,"queue_score":2,"hygiene_score":2,"service_score":2}`)
	if second.Code != http.StatusCreated {
		t.Fatalf("second status=%d body=%s", second.Code, second.Body.String())
	}
	var eventCount int64
	h.db.Model(&models.CanteenReviewEvent{}).Where("canteen_id = ? AND user_id = ?", canteen.ID, user.ID).Count(&eventCount)
	if eventCount != 2 {
		t.Fatalf("event count=%d want 2", eventCount)
	}
	var summary models.CanteenRating
	if err := h.db.Where("canteen_id = ? AND user_id = ?", canteen.ID, user.ID).First(&summary).Error; err != nil {
		t.Fatalf("load summary: %v", err)
	}
	if summary.ReviewEventCount != 2 || summary.ScoreVersion != 2 || summary.EffectiveScore < 2.72 || summary.EffectiveScore > 2.74 {
		t.Fatalf("summary=%+v", summary)
	}

	latest := performCanteenRequest(t, h.GetReviews, http.MethodGet,
		"/api/canteens/88/reviews", mapParams("id", "88"), 0, "")
	if latest.Code != http.StatusOK || !containsReviewJSONCount(latest.Body.Bytes(), 1) {
		t.Fatalf("latest response=%d body=%s", latest.Code, latest.Body.String())
	}
	history := performCanteenRequest(t, h.GetReviews, http.MethodGet,
		"/api/canteens/88/reviews?history=1", mapParams("id", "88"), 0, "")
	if history.Code != http.StatusOK || !containsReviewJSONCount(history.Body.Bytes(), 2) {
		t.Fatalf("history response=%d body=%s", history.Code, history.Body.String())
	}
}

func TestCreateReviewRateLimitsWithinSixHours(t *testing.T) {
	h, _, user := prepareReviewV2DB(t)
	first := performCanteenRequest(t, h.CreateReview, http.MethodPost,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID, reviewBody())
	if first.Code != http.StatusCreated {
		t.Fatalf("first status=%d", first.Code)
	}
	second := performCanteenRequest(t, h.CreateReview, http.MethodPost,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID, reviewBody())
	if second.Code != http.StatusTooManyRequests || !containsReviewJSONCode(second.Body.Bytes(), "review_too_frequent") {
		t.Fatalf("second status=%d body=%s", second.Code, second.Body.String())
	}
}

func TestDishSuggestionsDistinguishExactAndPossible(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	dish := models.CanteenDish{CanteenID: canteen.ID, Name: "辣子鸡", NormalizedName: "辣子鸡", Status: models.DishStatusActive, CreatedBy: user.ID}
	if err := h.db.Create(&dish).Error; err != nil {
		t.Fatalf("create dish: %v", err)
	}
	resp := performCanteenRequest(t, h.GetDishSuggestions, http.MethodGet,
		"/api/canteens/88/dish-suggestions?q=辣子鸡", mapParams("id", "88"), 0, "")
	if resp.Code != http.StatusOK || !containsReviewJSONCode(resp.Body.Bytes(), "exact") {
		t.Fatalf("exact response=%d body=%s", resp.Code, resp.Body.String())
	}
	resp = performCanteenRequest(t, h.GetDishSuggestions, http.MethodGet,
		"/api/canteens/88/dish-suggestions?q=辣子", mapParams("id", "88"), 0, "")
	if resp.Code != http.StatusOK || !containsReviewJSONCode(resp.Body.Bytes(), "possible") {
		t.Fatalf("possible response=%d body=%s", resp.Code, resp.Body.String())
	}
}

func mapParams(key, value string) []gin.Param {
	return []gin.Param{{Key: key, Value: value}}
}

func containsReviewJSONCode(body []byte, code string) bool {
	var value map[string]any
	if json.Unmarshal(body, &value) != nil {
		return false
	}
	data, _ := json.Marshal(value)
	return string(data) != "" && string(data) != "null" && string(data) != "{}" && string(data) != "[]" && containsString(body, code)
}

func containsReviewJSONCount(body []byte, expected int) bool {
	var value map[string]any
	if json.Unmarshal(body, &value) != nil {
		return false
	}
	got, _ := value["count"].(float64)
	return int(got) == expected
}

func containsString(body []byte, value string) bool {
	for i := 0; i+len(value) <= len(body); i++ {
		if string(body[i:i+len(value)]) == value {
			return true
		}
	}
	return false
}
