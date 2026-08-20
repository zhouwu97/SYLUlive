package handlers

import (
	"encoding/json"
	"net/http"
	"strings"
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

func TestCreateReviewPreservesLegacyHistoryAndBlocksLegacyRate(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	legacy := models.CanteenRating{CanteenID: canteen.ID, UserID: user.ID, Star: 4, Comment: "旧版"}
	if err := h.db.Create(&legacy).Error; err != nil {
		t.Fatal(err)
	}
	created := performCanteenRequest(t, h.CreateReview, http.MethodPost,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID, reviewBody())
	if created.Code != http.StatusCreated {
		t.Fatalf("create review status=%d body=%s", created.Code, created.Body.String())
	}
	var events []models.CanteenReviewEvent
	if err := h.db.Order("id ASC").Find(&events).Error; err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 || events[0].ScoreVersion != 1 || events[0].OverallScore != 4 || events[1].ScoreVersion != 2 {
		t.Fatalf("legacy history not retained: %+v", events)
	}
	rate := performCanteenRequest(t, h.Rate, http.MethodPost,
		"/api/canteens/88/rate", mapParams("id", "88"), user.ID, `{"star":5}`)
	if rate.Code != http.StatusConflict || !strings.Contains(rate.Body.String(), "legacy_rating_superseded") {
		t.Fatalf("legacy /rate status=%d body=%s", rate.Code, rate.Body.String())
	}
}

func TestGetReviewsDeduplicatesBeforeBestSortAndUsesStableCursor(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	verifiedAt := time.Now()
	secondUser := models.User{ID: 89, StudentID: "student-89", PasswordHash: "test", Nickname: "第二位", CreditScore: 80, StudentVerifiedAt: &verifiedAt}
	if err := h.db.Create(&secondUser).Error; err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	events := []models.CanteenReviewEvent{
		{CanteenID: canteen.ID, UserID: user.ID, OverallScore: 5, TasteScore: 5, ValueScore: 5, QueueScore: 5, HygieneScore: 5, ServiceScore: 5, Images: `[]`, Status: models.ReviewEventStatusActive, ScoreVersion: 2, CreatedAt: now.Add(-3 * time.Hour)},
		{CanteenID: canteen.ID, UserID: user.ID, OverallScore: 1, TasteScore: 1, ValueScore: 1, QueueScore: 1, HygieneScore: 1, ServiceScore: 1, Images: `[]`, Status: models.ReviewEventStatusActive, ScoreVersion: 2, CreatedAt: now.Add(-time.Hour)},
		{CanteenID: canteen.ID, UserID: secondUser.ID, OverallScore: 4, TasteScore: 4, ValueScore: 4, QueueScore: 4, HygieneScore: 4, ServiceScore: 4, Images: `[]`, Status: models.ReviewEventStatusActive, ScoreVersion: 2, CreatedAt: now.Add(-2 * time.Hour)},
	}
	if err := h.db.Create(&events).Error; err != nil {
		t.Fatal(err)
	}
	first := performCanteenRequest(t, h.GetReviews, http.MethodGet,
		"/api/canteens/88/reviews?sort=best&limit=1", mapParams("id", "88"), 0, "")
	if first.Code != http.StatusOK {
		t.Fatalf("first page status=%d body=%s", first.Code, first.Body.String())
	}
	var firstBody struct {
		Items      []models.CanteenReviewEvent `json:"items"`
		NextCursor string                      `json:"next_cursor"`
	}
	if err := json.Unmarshal(first.Body.Bytes(), &firstBody); err != nil {
		t.Fatal(err)
	}
	if len(firstBody.Items) != 1 || firstBody.Items[0].UserID != secondUser.ID || firstBody.NextCursor == "" {
		t.Fatalf("best page was sorted before dedup or cursor missing: %+v", firstBody)
	}
	second := performCanteenRequest(t, h.GetReviews, http.MethodGet,
		"/api/canteens/88/reviews?sort=best&limit=1&cursor="+firstBody.NextCursor, mapParams("id", "88"), 0, "")
	if second.Code != http.StatusOK {
		t.Fatalf("second page status=%d body=%s", second.Code, second.Body.String())
	}
	var secondBody struct{ Items []models.CanteenReviewEvent `json:"items"` }
	if err := json.Unmarshal(second.Body.Bytes(), &secondBody); err != nil {
		t.Fatal(err)
	}
	if len(secondBody.Items) != 1 || secondBody.Items[0].UserID == secondUser.ID {
		t.Fatalf("cursor repeated user or skipped latest user: %+v", secondBody)
	}
	for _, filter := range []string{"with_image", "high", "low"} {
		resp := performCanteenRequest(t, h.GetReviews, http.MethodGet,
			"/api/canteens/88/reviews?filter="+filter, mapParams("id", "88"), 0, "")
		if resp.Code != http.StatusOK {
			t.Fatalf("filter %s status=%d body=%s", filter, resp.Code, resp.Body.String())
		}
	}
	invalid := performCanteenRequest(t, h.GetReviews, http.MethodGet,
		"/api/canteens/88/reviews?filter=comment", mapParams("id", "88"), 0, "")
	if invalid.Code != http.StatusBadRequest {
		t.Fatalf("free-text filter should be rejected, status=%d body=%s", invalid.Code, invalid.Body.String())
	}
}

func TestCreateDishReviewValidatesParentEventOwnershipAndCanteen(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	otherUser := models.User{ID: 90, StudentID: "student-90", PasswordHash: "test", Nickname: "其他", StudentVerifiedAt: user.StudentVerifiedAt}
	if err := h.db.Create(&otherUser).Error; err != nil {
		t.Fatal(err)
	}
	dish := models.CanteenDish{CanteenID: canteen.ID, Name: "鱼香肉丝", NormalizedName: "鱼香肉丝", Status: models.DishStatusActive, CreatedBy: user.ID}
	if err := h.db.Create(&dish).Error; err != nil {
		t.Fatal(err)
	}
	ownedByOther := models.CanteenReviewEvent{CanteenID: canteen.ID, UserID: otherUser.ID, OverallScore: 4, Status: models.ReviewEventStatusActive, ScoreVersion: 2}
	if err := h.db.Create(&ownedByOther).Error; err != nil {
		t.Fatal(err)
	}
	forbidden := performCanteenRequest(t, h.CreateDishReview, http.MethodPost,
		"/api/canteens/dishes/"+itoaForTest(dish.ID)+"/reviews", mapParams("dishId", itoaForTest(dish.ID)), user.ID,
		`{"taste_score":4,"value_score":4,"portion_score":4,"canteen_review_event_id":`+itoaForTest(ownedByOther.ID)+`}`)
	if forbidden.Code != http.StatusForbidden {
		t.Fatalf("cross-user parent event status=%d body=%s", forbidden.Code, forbidden.Body.String())
	}
	otherCanteen := models.Canteen{ID: 99, Name: "二食堂", Image: "/uploads/2.png", CreatedBy: user.ID, Verified: true}
	if err := h.db.Create(&otherCanteen).Error; err != nil {
		t.Fatal(err)
	}
	wrongCanteen := models.CanteenReviewEvent{CanteenID: otherCanteen.ID, UserID: user.ID, OverallScore: 4, Status: models.ReviewEventStatusActive, ScoreVersion: 2}
	if err := h.db.Create(&wrongCanteen).Error; err != nil {
		t.Fatal(err)
	}
	invalid := performCanteenRequest(t, h.CreateDishReview, http.MethodPost,
		"/api/canteens/dishes/"+itoaForTest(dish.ID)+"/reviews", mapParams("dishId", itoaForTest(dish.ID)), user.ID,
		`{"taste_score":4,"value_score":4,"portion_score":4,"canteen_review_event_id":`+itoaForTest(wrongCanteen.ID)+`}`)
	if invalid.Code != http.StatusBadRequest {
		t.Fatalf("cross-canteen parent event status=%d body=%s", invalid.Code, invalid.Body.String())
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
