package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newCanteenTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.Canteen{},
		&models.CanteenRating{},
		&models.CanteenRatingVote{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

func createCanteenTestUser(t *testing.T, db *gorm.DB, id uint, nickname string) models.User {
	t.Helper()
	user := models.User{
		ID:           id,
		StudentID:    fmt.Sprintf("student-%d", id),
		PasswordHash: "test",
		Nickname:     nickname,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	return user
}

func performCanteenRequest(
	t *testing.T,
	handler gin.HandlerFunc,
	method string,
	path string,
	params gin.Params,
	userID uint,
	body string,
) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(method, path, strings.NewReader(body))
	context.Request.Header.Set("Content-Type", "application/json")
	context.Params = params
	context.Set("user_id", userID)
	handler(context)
	return recorder
}

func TestCanteenVoteRatingTogglesAndReturnsCounts(t *testing.T) {
	db := newCanteenTestDB(t)
	createCanteenTestUser(t, db, 1, "Alice")
	createCanteenTestUser(t, db, 2, "Bob")
	canteen := models.Canteen{Name: "外卖", Image: "/uploads/canteen.png", CreatedBy: 1}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatalf("create canteen: %v", err)
	}
	rating := models.CanteenRating{CanteenID: canteen.ID, UserID: 2, Star: 4, Comment: "还行"}
	if err := db.Create(&rating).Error; err != nil {
		t.Fatalf("create rating: %v", err)
	}
	handler := NewCanteenHandler(db)

	steps := []struct {
		vote      string
		helpful   int
		unhelpful int
		myVote    *string
	}{
		{vote: "up", helpful: 1, unhelpful: 0, myVote: strPtr("up")},
		{vote: "up", helpful: 0, unhelpful: 0, myVote: nil},
		{vote: "down", helpful: 0, unhelpful: 1, myVote: strPtr("down")},
		{vote: "up", helpful: 1, unhelpful: 0, myVote: strPtr("up")},
		{vote: "none", helpful: 0, unhelpful: 0, myVote: nil},
	}

	for _, step := range steps {
		response := performCanteenRequest(
			t,
			handler.VoteRating,
			http.MethodPut,
			fmt.Sprintf("/api/canteens/ratings/%d/vote", rating.ID),
			gin.Params{{Key: "ratingId", Value: fmt.Sprint(rating.ID)}},
			1,
			fmt.Sprintf(`{"vote":"%s"}`, step.vote),
		)
		if response.Code != http.StatusOK {
			t.Fatalf("vote %s status=%d body=%s", step.vote, response.Code, response.Body.String())
		}
		var body struct {
			HelpfulCount   int     `json:"helpful_count"`
			UnhelpfulCount int     `json:"unhelpful_count"`
			MyVote         *string `json:"my_vote"`
		}
		if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
			t.Fatalf("decode response: %v", err)
		}
		if body.HelpfulCount != step.helpful ||
			body.UnhelpfulCount != step.unhelpful ||
			!sameStringPtr(body.MyVote, step.myVote) {
			t.Fatalf("vote %s got helpful=%d unhelpful=%d my_vote=%v",
				step.vote, body.HelpfulCount, body.UnhelpfulCount, body.MyVote)
		}
	}
}

func TestCanteenVoteRatingRejectsInvalidMissingAndOwnRating(t *testing.T) {
	db := newCanteenTestDB(t)
	createCanteenTestUser(t, db, 1, "Alice")
	canteen := models.Canteen{Name: "外卖", Image: "/uploads/canteen.png", CreatedBy: 1}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatalf("create canteen: %v", err)
	}
	rating := models.CanteenRating{CanteenID: canteen.ID, UserID: 1, Star: 4}
	if err := db.Create(&rating).Error; err != nil {
		t.Fatalf("create rating: %v", err)
	}
	handler := NewCanteenHandler(db)

	invalid := performCanteenRequest(
		t,
		handler.VoteRating,
		http.MethodPut,
		"/api/canteens/ratings/999/vote",
		gin.Params{{Key: "ratingId", Value: "999"}},
		1,
		`{"vote":"maybe"}`,
	)
	if invalid.Code != http.StatusBadRequest {
		t.Fatalf("invalid vote status=%d body=%s", invalid.Code, invalid.Body.String())
	}

	missing := performCanteenRequest(
		t,
		handler.VoteRating,
		http.MethodPut,
		"/api/canteens/ratings/999/vote",
		gin.Params{{Key: "ratingId", Value: "999"}},
		1,
		`{"vote":"up"}`,
	)
	if missing.Code != http.StatusNotFound {
		t.Fatalf("missing rating status=%d body=%s", missing.Code, missing.Body.String())
	}

	own := performCanteenRequest(
		t,
		handler.VoteRating,
		http.MethodPut,
		fmt.Sprintf("/api/canteens/ratings/%d/vote", rating.ID),
		gin.Params{{Key: "ratingId", Value: fmt.Sprint(rating.ID)}},
		1,
		`{"vote":"up"}`,
	)
	if own.Code != http.StatusBadRequest ||
		!strings.Contains(own.Body.String(), "不能给自己的评价投票") {
		t.Fatalf("own rating status=%d body=%s", own.Code, own.Body.String())
	}
}

func TestCanteenDetailSortFilterAndMyVote(t *testing.T) {
	db := newCanteenTestDB(t)
	createCanteenTestUser(t, db, 1, "Alice")
	createCanteenTestUser(t, db, 2, "Bob")
	createCanteenTestUser(t, db, 3, "Cathy")
	canteen := models.Canteen{Name: "外卖", Image: "/uploads/canteen.png", CreatedBy: 1}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatalf("create canteen: %v", err)
	}
	ratings := []models.CanteenRating{
		{CanteenID: canteen.ID, UserID: 2, Star: 5, Comment: "   ", HelpfulCount: 10},
		{CanteenID: canteen.ID, UserID: 3, Star: 4, Comment: "有参考价值", Images: `["/uploads/a.png"]`, HelpfulCount: 5},
		{CanteenID: canteen.ID, UserID: 2, Star: 4, Comment: "   ", HelpfulCount: 5},
		{CanteenID: canteen.ID, UserID: 2, Star: 1, Comment: "踩雷", UnhelpfulCount: 1},
	}
	if err := db.Create(&ratings).Error; err != nil {
		t.Fatalf("create ratings: %v", err)
	}
	if err := db.Create(&models.CanteenRatingVote{
		RatingID: ratings[1].ID,
		UserID:   1,
		VoteType: "up",
	}).Error; err != nil {
		t.Fatalf("create vote: %v", err)
	}
	handler := NewCanteenHandler(db)

	best := performCanteenRequest(
		t,
		handler.GetDetail,
		http.MethodGet,
		fmt.Sprintf("/api/canteens/%d?review_sort=best&review_filter=all", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
		1,
		"",
	)
	if best.Code != http.StatusOK {
		t.Fatalf("best status=%d body=%s", best.Code, best.Body.String())
	}
	var bestBody struct {
		Ratings []struct {
			ID     uint    `json:"id"`
			MyVote *string `json:"my_vote"`
		} `json:"ratings"`
	}
	if err := json.Unmarshal(best.Body.Bytes(), &bestBody); err != nil {
		t.Fatalf("decode best: %v", err)
	}
	if len(bestBody.Ratings) != 4 ||
		bestBody.Ratings[0].ID != ratings[0].ID ||
		bestBody.Ratings[1].ID != ratings[1].ID {
		t.Fatalf("unexpected best order: %s", best.Body.String())
	}
	if !sameStringPtr(bestBody.Ratings[1].MyVote, strPtr("up")) {
		t.Fatalf("expected my_vote on second rating: %s", best.Body.String())
	}

	withImage := performCanteenRequest(
		t,
		handler.GetDetail,
		http.MethodGet,
		fmt.Sprintf("/api/canteens/%d?review_filter=with_image", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
		1,
		"",
	)
	if withImage.Code != http.StatusOK {
		t.Fatalf("with_image status=%d body=%s", withImage.Code, withImage.Body.String())
	}
	var imageBody struct {
		Ratings []struct {
			ID uint `json:"id"`
		} `json:"ratings"`
	}
	if err := json.Unmarshal(withImage.Body.Bytes(), &imageBody); err != nil {
		t.Fatalf("decode with_image: %v", err)
	}
	if len(imageBody.Ratings) != 1 || imageBody.Ratings[0].ID != ratings[1].ID {
		t.Fatalf("unexpected with_image ratings: %s", withImage.Body.String())
	}
}

func strPtr(value string) *string {
	return &value
}

func sameStringPtr(a, b *string) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}
