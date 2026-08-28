package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"shenliyuan/internal/models"
)

func prepareReviewV2DB(t *testing.T) (*CanteenHandler, models.Canteen, models.User) {
	t.Helper()
	uploadDir := t.TempDir()
	t.Setenv("UPLOAD_DIR", uploadDir)
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

func TestCreateReviewCreatesActiveDishDirectly(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	response := performCanteenRequest(t, h.CreateReview, http.MethodPost,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID,
		`{"taste_score":5,"value_score":4,"queue_score":4,"hygiene_score":4,"service_score":4,"comment":"铁板豆腐不错","dish_names":["铁板豆腐"]}`)
	if response.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", response.Code, response.Body.String())
	}
	var dish models.CanteenDish
	if err := h.db.Where("canteen_id = ? AND normalized_name = ?", canteen.ID, "铁板豆腐").First(&dish).Error; err != nil {
		t.Fatalf("dish missing: %v", err)
	}
	if dish.Status != models.DishStatusActive || dish.CreatedBy != user.ID {
		t.Fatalf("dish=%+v want active status", dish)
	}
	var relation models.CanteenReviewEventDish
	if err := h.db.Where("dish_id = ?", dish.ID).First(&relation).Error; err != nil {
		t.Fatalf("review relation missing: %v", err)
	}
	contributions := performCanteenRequest(t, h.GetMyCanteenContributions, http.MethodGet,
		"/api/user/canteen-contributions", nil, user.ID, "")
	if contributions.Code != http.StatusOK || !strings.Contains(contributions.Body.String(), "铁板豆腐") ||
		!strings.Contains(contributions.Body.String(), models.DishStatusActive) {
		t.Fatalf("contributions status=%d body=%s", contributions.Code, contributions.Body.String())
	}
}

func TestUpdateReviewDoesNotReviveRejectedDish(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	dish := models.CanteenDish{
		CanteenID: canteen.ID, Name: "被驳回菜", NormalizedName: "被驳回菜",
		Status: models.DishStatusRejected, CreatedBy: user.ID, RejectReason: "无法确认菜品来源",
	}
	if err := h.db.Create(&dish).Error; err != nil {
		t.Fatal(err)
	}
	event := models.CanteenReviewEvent{
		CanteenID: canteen.ID, UserID: user.ID, TasteScore: 4, ValueScore: 4,
		QueueScore: 4, HygieneScore: 4, ServiceScore: 4, OverallScore: 4,
		Comment: "原评价", Status: models.ReviewEventStatusActive, ScoreVersion: 2,
	}
	if err := h.db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	if err := h.db.Create(&models.CanteenReviewEventDish{
		ReviewEventID: event.ID, DishID: dish.ID, Relation: models.DishReviewRelationAte,
	}).Error; err != nil {
		t.Fatal(err)
	}

	updated := performCanteenRequest(t, h.UpdateReview, http.MethodPatch,
		"/api/canteens/reviews/"+itoaForTest(event.ID),
		mapParams("reviewId", itoaForTest(event.ID)), user.ID,
		fmt.Sprintf(`{"taste_score":5,"value_score":4,"queue_score":4,"hygiene_score":4,"service_score":4,"comment":"修改文字","dish_ids":[%d]}`, dish.ID))
	if updated.Code != http.StatusOK {
		t.Fatalf("update status=%d body=%s", updated.Code, updated.Body.String())
	}
	var refreshed models.CanteenDish
	if err := h.db.First(&refreshed, dish.ID).Error; err != nil {
		t.Fatal(err)
	}
	if refreshed.Status != models.DishStatusRejected || refreshed.RejectReason != dish.RejectReason {
		t.Fatalf("rejected dish was revived: %+v", refreshed)
	}
}

func TestResubmitDishExplicitlyRevivesRejectedDish(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	dish := models.CanteenDish{
		CanteenID: canteen.ID, Name: "可重提菜", NormalizedName: "可重提菜",
		Status: models.DishStatusRejected, CreatedBy: user.ID, RejectReason: "请补充来源",
	}
	if err := h.db.Create(&dish).Error; err != nil {
		t.Fatal(err)
	}
	response := performCanteenRequest(t, h.ResubmitDish, http.MethodPost,
		"/api/canteens/dishes/"+itoaForTest(dish.ID)+"/resubmit",
		mapParams("dishId", itoaForTest(dish.ID)), user.ID, "")
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "已重新提交审核") {
		t.Fatalf("resubmit status=%d body=%s", response.Code, response.Body.String())
	}
	var refreshed models.CanteenDish
	if err := h.db.First(&refreshed, dish.ID).Error; err != nil {
		t.Fatal(err)
	}
	if refreshed.Status != models.DishStatusPending || refreshed.RejectReason != "" {
		t.Fatalf("dish after resubmit=%+v", refreshed)
	}
}

func TestReviewDishNamesAndPhotosRespectViewerVisibility(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	activeDish := models.CanteenDish{
		CanteenID: canteen.ID, Name: "公开菜", NormalizedName: "公开菜",
		Status: models.DishStatusActive, CreatedBy: user.ID,
	}
	pendingDish := models.CanteenDish{
		CanteenID: canteen.ID, Name: "待收录菜", NormalizedName: "待收录菜",
		Status: models.DishStatusPending, CreatedBy: user.ID,
	}
	rejectedDish := models.CanteenDish{
		CanteenID: canteen.ID, Name: "未通过菜", NormalizedName: "未通过菜",
		Status: models.DishStatusRejected, CreatedBy: user.ID, RejectReason: "菜名无法核实",
	}
	for _, dish := range []*models.CanteenDish{&activeDish, &pendingDish, &rejectedDish} {
		if err := h.db.Create(dish).Error; err != nil {
			t.Fatal(err)
		}
	}
	event := models.CanteenReviewEvent{
		CanteenID: canteen.ID, UserID: user.ID, TasteScore: 4, ValueScore: 4,
		QueueScore: 4, HygieneScore: 4, ServiceScore: 4, OverallScore: 4,
		Images: `[]`, Status: models.ReviewEventStatusActive, ScoreVersion: 2,
	}
	if err := h.db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	for _, dish := range []*models.CanteenDish{&activeDish, &pendingDish, &rejectedDish} {
		if err := h.db.Create(&models.CanteenReviewEventDish{
			ReviewEventID: event.ID, DishID: dish.ID, Relation: models.DishReviewRelationAte,
		}).Error; err != nil {
			t.Fatal(err)
		}
	}
	approvedFile := models.File{Path: "/uploads/approved.jpg", Hash: "review-approved", Size: 1, MimeType: "image/jpeg"}
	pendingFile := models.File{Path: "/uploads/pending.jpg", Hash: "review-pending", Size: 1, MimeType: "image/jpeg"}
	rejectedFile := models.File{Path: "/uploads/rejected.jpg", Hash: "review-rejected", Size: 1, MimeType: "image/jpeg"}
	for _, file := range []*models.File{&approvedFile, &pendingFile, &rejectedFile} {
		if err := h.db.Create(file).Error; err != nil {
			t.Fatal(err)
		}
	}
	photos := []models.CanteenDishPhoto{
		{DishID: activeDish.ID, FileID: approvedFile.ID, UserID: user.ID, Status: models.DishPhotoStatusApproved, ReviewEventID: &event.ID},
		{DishID: pendingDish.ID, FileID: pendingFile.ID, UserID: user.ID, Status: models.DishPhotoStatusPending, ReviewEventID: &event.ID},
		{DishID: rejectedDish.ID, FileID: rejectedFile.ID, UserID: user.ID, Status: models.DishPhotoStatusRejected, RejectReason: "图片模糊", ReviewEventID: &event.ID},
	}
	if err := h.db.Create(&photos).Error; err != nil {
		t.Fatal(err)
	}

	publicResponse := performCanteenRequest(t, h.GetReviews, http.MethodGet,
		"/api/canteens/88/reviews", mapParams("id", "88"), 0, "")
	if publicResponse.Code != http.StatusOK {
		t.Fatalf("public status=%d body=%s", publicResponse.Code, publicResponse.Body.String())
	}
	if strings.Contains(publicResponse.Body.String(), "未通过菜") ||
		strings.Contains(publicResponse.Body.String(), "图片模糊") ||
		!strings.Contains(publicResponse.Body.String(), "approved.jpg") {
		t.Fatalf("public visibility is wrong: %s", publicResponse.Body.String())
	}

	ownerResponse := performCanteenRequest(t, h.GetReviews, http.MethodGet,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID, "")
	if ownerResponse.Code != http.StatusOK ||
		!strings.Contains(ownerResponse.Body.String(), "未通过菜") ||
		!strings.Contains(ownerResponse.Body.String(), "图片模糊") ||
		!strings.Contains(ownerResponse.Body.String(), "pending.jpg") {
		t.Fatalf("owner visibility is wrong: %s", ownerResponse.Body.String())
	}
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

func TestCreateReviewAllowsImmediateRepeat(t *testing.T) {
	h, _, user := prepareReviewV2DB(t)
	first := performCanteenRequest(t, h.CreateReview, http.MethodPost,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID, reviewBody())
	if first.Code != http.StatusCreated {
		t.Fatalf("first status=%d", first.Code)
	}
	second := performCanteenRequest(t, h.CreateReview, http.MethodPost,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID, reviewBody())
	if second.Code != http.StatusCreated {
		t.Fatalf("second status=%d body=%s", second.Code, second.Body.String())
	}
	var eventCount int64
	if err := h.db.Model(&models.CanteenReviewEvent{}).Where("canteen_id = ? AND user_id = ?", 88, user.ID).Count(&eventCount).Error; err != nil {
		t.Fatal(err)
	}
	if eventCount != 2 {
		t.Fatalf("event count=%d want 2", eventCount)
	}
}

func TestDeleteReviewOwnActiveIsIdempotent(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	created := performCanteenRequest(t, h.CreateReview, http.MethodPost,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID, reviewBody())
	if created.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", created.Code, created.Body.String())
	}
	var event models.CanteenReviewEvent
	if err := h.db.Where("canteen_id = ?", canteen.ID).First(&event).Error; err != nil {
		t.Fatal(err)
	}

	deleted := performCanteenRequest(t, h.DeleteReview, http.MethodDelete,
		"/api/canteens/reviews/"+itoaForTest(event.ID), mapParams("reviewId", itoaForTest(event.ID)), user.ID, "")
	if deleted.Code != http.StatusOK || strings.Contains(deleted.Body.String(), `"already_deleted":true`) {
		t.Fatalf("first delete status=%d body=%s", deleted.Code, deleted.Body.String())
	}
	if err := h.db.First(&event, event.ID).Error; err != nil || event.Status != models.ReviewEventStatusDeleted {
		t.Fatalf("event after delete=%+v err=%v", event, err)
	}

	repeated := performCanteenRequest(t, h.DeleteReview, http.MethodDelete,
		"/api/canteens/reviews/"+itoaForTest(event.ID), mapParams("reviewId", itoaForTest(event.ID)), user.ID, "")
	if repeated.Code != http.StatusOK || !strings.Contains(repeated.Body.String(), `"already_deleted":true`) {
		t.Fatalf("second delete status=%d body=%s", repeated.Code, repeated.Body.String())
	}
}

func TestDeleteReviewRejectsOtherUserAndHidden(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	other := models.User{ID: 89, StudentID: "student-89", PasswordHash: "test", Nickname: "另一位同学"}
	if err := h.db.Create(&other).Error; err != nil {
		t.Fatal(err)
	}
	event := models.CanteenReviewEvent{
		CanteenID: canteen.ID, UserID: user.ID, OverallScore: 4,
		Status: models.ReviewEventStatusActive, ScoreVersion: 2,
		CreatedAt: time.Now(), UpdatedAt: time.Now(),
	}
	if err := h.db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	forbidden := performCanteenRequest(t, h.DeleteReview, http.MethodDelete,
		"/api/canteens/reviews/"+itoaForTest(event.ID), mapParams("reviewId", itoaForTest(event.ID)), other.ID, "")
	if forbidden.Code != http.StatusForbidden {
		t.Fatalf("other user status=%d body=%s", forbidden.Code, forbidden.Body.String())
	}
	if err := h.db.Model(&event).Update("status", models.ReviewEventStatusHidden).Error; err != nil {
		t.Fatal(err)
	}
	hidden := performCanteenRequest(t, h.DeleteReview, http.MethodDelete,
		"/api/canteens/reviews/"+itoaForTest(event.ID), mapParams("reviewId", itoaForTest(event.ID)), user.ID, "")
	if hidden.Code != http.StatusConflict || !containsReviewJSONCode(hidden.Body.Bytes(), "review_not_active") {
		t.Fatalf("hidden status=%d body=%s", hidden.Code, hidden.Body.String())
	}
}

func TestDeletedLatestAllowsImmediateCreate(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	created := performCanteenRequest(t, h.CreateReview, http.MethodPost,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID, reviewBody())
	if created.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", created.Code, created.Body.String())
	}
	var event models.CanteenReviewEvent
	if err := h.db.Where("canteen_id = ?", canteen.ID).First(&event).Error; err != nil {
		t.Fatal(err)
	}
	if err := h.db.Model(&event).Update("created_at", time.Now().Add(-time.Hour)).Error; err != nil {
		t.Fatal(err)
	}
	deleted := performCanteenRequest(t, h.DeleteReview, http.MethodDelete,
		"/api/canteens/reviews/"+itoaForTest(event.ID), mapParams("reviewId", itoaForTest(event.ID)), user.ID, "")
	if deleted.Code != http.StatusOK {
		t.Fatalf("delete status=%d body=%s", deleted.Code, deleted.Body.String())
	}
	createdAgain := performCanteenRequest(t, h.CreateReview, http.MethodPost,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID, reviewBody())
	if createdAgain.Code != http.StatusCreated {
		t.Fatalf("create after delete status=%d body=%s", createdAgain.Code, createdAgain.Body.String())
	}
}

func TestDeletingLatestDoesNotMakeOlderReviewEditable(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	older := models.CanteenReviewEvent{
		CanteenID: canteen.ID, UserID: user.ID, TasteScore: 4, ValueScore: 4, QueueScore: 4, HygieneScore: 4, ServiceScore: 4,
		OverallScore: 4, Comment: "旧评价", Status: models.ReviewEventStatusActive, ScoreVersion: 2,
		CreatedAt: time.Now().Add(-8 * time.Hour), UpdatedAt: time.Now().Add(-8 * time.Hour),
	}
	latest := older
	latest.ID = 0
	latest.Comment = "新评价"
	latest.CreatedAt = time.Now().Add(-time.Hour)
	latest.UpdatedAt = latest.CreatedAt
	if err := h.db.Create(&older).Error; err != nil {
		t.Fatal(err)
	}
	if err := h.db.Create(&latest).Error; err != nil {
		t.Fatal(err)
	}
	deleted := performCanteenRequest(t, h.DeleteReview, http.MethodDelete,
		"/api/canteens/reviews/"+itoaForTest(latest.ID), mapParams("reviewId", itoaForTest(latest.ID)), user.ID, "")
	if deleted.Code != http.StatusOK {
		t.Fatalf("delete status=%d body=%s", deleted.Code, deleted.Body.String())
	}
	update := performCanteenRequest(t, h.UpdateReview, http.MethodPatch,
		"/api/canteens/reviews/"+itoaForTest(older.ID), mapParams("reviewId", itoaForTest(older.ID)), user.ID, reviewBody())
	if update.Code != http.StatusConflict || !containsReviewJSONCode(update.Body.Bytes(), "review_not_latest") {
		t.Fatalf("update old status=%d body=%s", update.Code, update.Body.String())
	}
}

func TestGetMyCanteenReviewsNewestFirstAndCursorIncludesLegacyAndOffline(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	now := time.Now()
	v2 := models.CanteenReviewEvent{
		CanteenID: canteen.ID, UserID: user.ID, TasteScore: 5, ValueScore: 4, QueueScore: 4, HygieneScore: 5, ServiceScore: 4,
		OverallScore: 4.4, Comment: "新版评价", Images: `[]`, Tags: `[]`, Status: models.ReviewEventStatusActive, ScoreVersion: 2,
		CreatedAt: now.Add(-time.Hour), UpdatedAt: now.Add(-time.Hour),
	}
	if err := h.db.Create(&v2).Error; err != nil {
		t.Fatal(err)
	}
	offline := models.Canteen{ID: 89, Name: "二食堂", Image: "/uploads/offline.png", Verified: true, OperatingStatus: models.CanteenOperatingOffline, CreatedBy: user.ID}
	if err := h.db.Create(&offline).Error; err != nil {
		t.Fatal(err)
	}
	legacy := models.CanteenRating{
		CanteenID: offline.ID, UserID: user.ID, Star: 3, Comment: "旧版评价", Images: `[]`, Status: models.ReviewEventStatusActive,
		CreatedAt: now.Add(-2 * time.Hour), UpdatedAt: now.Add(-2 * time.Hour),
	}
	if err := h.db.Create(&legacy).Error; err != nil {
		t.Fatal(err)
	}

	first := performCanteenRequest(t, h.GetMyCanteenReviews, http.MethodGet,
		"/api/user/canteen-reviews?limit=1", nil, user.ID, "")
	if first.Code != http.StatusOK {
		t.Fatalf("first status=%d body=%s", first.Code, first.Body.String())
	}
	var firstBody struct {
		Items      []map[string]interface{} `json:"items"`
		NextCursor string                   `json:"next_cursor"`
	}
	if err := json.Unmarshal(first.Body.Bytes(), &firstBody); err != nil {
		t.Fatal(err)
	}
	if len(firstBody.Items) != 1 || firstBody.Items[0]["source"] != "v2" || firstBody.NextCursor == "" {
		t.Fatalf("first page=%+v", firstBody)
	}
	if firstBody.Items[0]["canteen"].(map[string]interface{})["name"] != canteen.Name {
		t.Fatalf("v2 canteen payload=%v", firstBody.Items[0]["canteen"])
	}
	second := performCanteenRequest(t, h.GetMyCanteenReviews, http.MethodGet,
		"/api/user/canteen-reviews?limit=20&cursor="+firstBody.NextCursor, nil, user.ID, "")
	if second.Code != http.StatusOK || !strings.Contains(second.Body.String(), `"source":"legacy"`) ||
		!strings.Contains(second.Body.String(), `"is_offline":true`) {
		t.Fatalf("second page status=%d body=%s", second.Code, second.Body.String())
	}
}

func TestCreateReviewRejectsMergedDishSelectionOverThree(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	for i := 1; i <= 4; i++ {
		dish := models.CanteenDish{
			CanteenID: canteen.ID, Name: "菜品" + itoaForTest(uint(i)), NormalizedName: "菜品" + itoaForTest(uint(i)),
			Status: models.DishStatusActive, CreatedBy: user.ID,
		}
		if err := h.db.Create(&dish).Error; err != nil {
			t.Fatal(err)
		}
	}
	response := performCanteenRequest(t, h.CreateReview, http.MethodPost,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID,
		`{"taste_score":5,"value_score":4,"queue_score":4,"hygiene_score":4,"service_score":4,"dish_ids":[1,2,3],"dish_reviews":[{"dish_id":4,"taste_score":4,"value_score":4,"portion_score":4}]}`)
	if response.Code != http.StatusBadRequest || !containsReviewJSONCode(response.Body.Bytes(), "invalid_review_dish") {
		t.Fatalf("merged dish selection status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestUpdateReviewRejectsMergedDishSelectionOverThree(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	var dishes []models.CanteenDish
	for i := 1; i <= 4; i++ {
		dish := models.CanteenDish{
			CanteenID: canteen.ID, Name: "菜品" + itoaForTest(uint(i)), NormalizedName: "菜品" + itoaForTest(uint(i)),
			Status: models.DishStatusActive, CreatedBy: user.ID,
		}
		if err := h.db.Create(&dish).Error; err != nil {
			t.Fatal(err)
		}
		dishes = append(dishes, dish)
	}
	event := models.CanteenReviewEvent{
		CanteenID: canteen.ID, UserID: user.ID, TasteScore: 5, ValueScore: 4,
		QueueScore: 4, HygieneScore: 4, ServiceScore: 4, OverallScore: 4.2,
		Status: models.ReviewEventStatusActive, ScoreVersion: 2,
	}
	if err := h.db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	response := performCanteenRequest(t, h.UpdateReview, http.MethodPatch,
		"/api/canteens/reviews/"+itoaForTest(event.ID), mapParams("reviewId", itoaForTest(event.ID)), user.ID,
		`{"taste_score":5,"value_score":4,"queue_score":4,"hygiene_score":4,"service_score":4,"dish_ids":[1,2,3],"dish_reviews":[{"dish_id":4,"taste_score":4,"value_score":4,"portion_score":4}]}`)
	if response.Code != http.StatusBadRequest || !containsReviewJSONCode(response.Body.Bytes(), "invalid_review_dish") {
		t.Fatalf("merged dish update status=%d body=%s", response.Code, response.Body.String())
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

func TestGetDetailReturnsEventLevelPayloadForEditing(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	dish := models.CanteenDish{
		CanteenID: canteen.ID, Name: "鸡排饭", NormalizedName: "鸡排饭",
		Status: models.DishStatusActive, CreatedBy: user.ID,
	}
	if err := h.db.Create(&dish).Error; err != nil {
		t.Fatal(err)
	}
	event := models.CanteenReviewEvent{
		CanteenID: canteen.ID, UserID: user.ID,
		TasteScore: 5, ValueScore: 4, QueueScore: 3, HygieneScore: 4, ServiceScore: 5,
		OverallScore: 4.35, Comment: "这次文字补充", Images: `["/uploads/review.jpg"]`,
		Tags: `["taste_good"]`, Status: models.ReviewEventStatusActive, ScoreVersion: 2,
	}
	if err := h.db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	if err := h.db.Create(&models.CanteenReviewEventDish{
		ReviewEventID: event.ID, DishID: dish.ID, Relation: models.DishReviewRelationAte,
	}).Error; err != nil {
		t.Fatal(err)
	}
	if err := h.db.Create(&models.CanteenDishReviewEvent{
		DishID: dish.ID, UserID: user.ID, TasteScore: 5, ValueScore: 4, PortionScore: 3,
		OverallScore: 4, Comment: "分量足", Status: models.ReviewEventStatusActive,
		ScoreVersion: 1, CanteenReviewEventID: &event.ID,
	}).Error; err != nil {
		t.Fatal(err)
	}

	response := performCanteenRequest(t, h.GetDetail, http.MethodGet,
		"/api/canteens/88", mapParams("id", "88"), user.ID, "")
	if response.Code != http.StatusOK {
		t.Fatalf("detail status=%d body=%s", response.Code, response.Body.String())
	}
	var body struct {
		Latest map[string]interface{} `json:"my_latest_review"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if got := int(body.Latest["review_event_id"].(float64)); got != int(event.ID) {
		t.Fatalf("latest event id=%d want %d", got, event.ID)
	}
	recommended, ok := body.Latest["recommended_dishes"].([]interface{})
	if !ok || len(recommended) != 1 {
		t.Fatalf("recommended dishes=%v", body.Latest["recommended_dishes"])
	}
	dishReviews, ok := body.Latest["dish_reviews"].([]interface{})
	if !ok || len(dishReviews) != 1 {
		t.Fatalf("dish reviews=%v", body.Latest["dish_reviews"])
	}
	var action map[string]interface{}
	if err := json.Unmarshal(response.Body.Bytes(), &struct {
		ReviewAction *map[string]interface{} `json:"review_action"`
	}{ReviewAction: &action}); err != nil {
		t.Fatal(err)
	}
	if action["can_edit_latest"] != true || action["latest_review_id"].(float64) != float64(event.ID) {
		t.Fatalf("review action=%v", action)
	}
	if action["can_create"] != true {
		t.Fatalf("unexpected create action=%v", action)
	}
}

func TestGetDetailReviewActionAllowsCreateImmediately(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	event := models.CanteenReviewEvent{
		CanteenID: canteen.ID, UserID: user.ID,
		TasteScore: 4, ValueScore: 4, QueueScore: 4, HygieneScore: 4, ServiceScore: 4,
		OverallScore: 4, Status: models.ReviewEventStatusActive, ScoreVersion: 2,
		CreatedAt: time.Now().Add(-7 * time.Hour), UpdatedAt: time.Now().Add(-7 * time.Hour),
	}
	if err := h.db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	response := performCanteenRequest(t, h.GetDetail, http.MethodGet,
		"/api/canteens/88", mapParams("id", "88"), user.ID, "")
	if response.Code != http.StatusOK {
		t.Fatalf("detail status=%d body=%s", response.Code, response.Body.String())
	}
	var body struct {
		ReviewAction map[string]interface{} `json:"review_action"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.ReviewAction["can_create"] != true ||
		body.ReviewAction["can_edit_latest"] != true ||
		body.ReviewAction["latest_review_id"].(float64) != float64(event.ID) {
		t.Fatalf("unexpected immediate-create action=%v", body.ReviewAction)
	}
}

func TestGetDetailReviewActionDoesNotEditLegacyOnlyHistory(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	legacy := models.CanteenRating{
		CanteenID: canteen.ID, UserID: user.ID, Star: 4, Comment: "旧版评价",
		Status: models.ReviewEventStatusActive,
	}
	if err := h.db.Create(&legacy).Error; err != nil {
		t.Fatal(err)
	}
	response := performCanteenRequest(t, h.GetDetail, http.MethodGet,
		"/api/canteens/88", mapParams("id", "88"), user.ID, "")
	if response.Code != http.StatusOK {
		t.Fatalf("detail status=%d body=%s", response.Code, response.Body.String())
	}
	var body struct {
		ReviewAction map[string]interface{} `json:"review_action"`
		Latest       interface{}            `json:"my_latest_review"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.ReviewAction["can_create"] != true || body.ReviewAction["can_edit_latest"] != false || body.Latest != nil {
		t.Fatalf("legacy history must remain create-only: action=%v latest=%v", body.ReviewAction, body.Latest)
	}
}

func TestEnsureLegacyReviewEventDoesNotResurrectHiddenRating(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	rating := models.CanteenRating{
		CanteenID: canteen.ID, UserID: user.ID, Star: 1,
		Comment: "已隐藏", Status: models.ReviewEventStatusHidden,
	}
	if err := h.db.Create(&rating).Error; err != nil {
		t.Fatal(err)
	}
	if err := ensureLegacyReviewEvent(h.db, canteen.ID, user.ID); err != nil {
		t.Fatal(err)
	}
	var count int64
	if err := h.db.Model(&models.CanteenReviewEvent{}).
		Where("canteen_id = ? AND user_id = ?", canteen.ID, user.ID).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("hidden legacy rating was copied into %d history events", count)
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
	var secondBody struct {
		Items []models.CanteenReviewEvent `json:"items"`
	}
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

func TestGetDishReviewsUsesParentCommentWithOptionalDishScore(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	other := models.User{ID: 90, StudentID: "student-90", PasswordHash: "test", Nickname: "另一位同学", CreditScore: 90}
	if err := h.db.Create(&other).Error; err != nil {
		t.Fatal(err)
	}
	dish := models.CanteenDish{
		CanteenID: canteen.ID, Name: "鱼香肉丝", NormalizedName: "鱼香肉丝",
		Status: models.DishStatusActive, CreatedBy: user.ID,
	}
	if err := h.db.Create(&dish).Error; err != nil {
		t.Fatal(err)
	}
	parentWithoutDishScore := models.CanteenReviewEvent{
		CanteenID: canteen.ID, UserID: user.ID, TasteScore: 5, ValueScore: 4,
		QueueScore: 4, HygieneScore: 4, ServiceScore: 4, OverallScore: 4.4,
		Comment: "主评价里写的鱼香肉丝很好吃", Status: models.ReviewEventStatusActive,
		ScoreVersion: 2, CreatedAt: time.Now().Add(-time.Hour), UpdatedAt: time.Now().Add(-time.Hour),
	}
	parentWithDishScore := models.CanteenReviewEvent{
		CanteenID: canteen.ID, UserID: other.ID, TasteScore: 4, ValueScore: 4,
		QueueScore: 3, HygieneScore: 4, ServiceScore: 4, OverallScore: 3.8,
		Comment: "主评价评论应该展示在菜品详情", Status: models.ReviewEventStatusActive,
		ScoreVersion: 2, CreatedAt: time.Now(), UpdatedAt: time.Now(),
	}
	if err := h.db.Create(&parentWithoutDishScore).Create(&parentWithDishScore).Error; err != nil {
		t.Fatal(err)
	}
	for _, parent := range []models.CanteenReviewEvent{parentWithoutDishScore, parentWithDishScore} {
		if err := h.db.Create(&models.CanteenReviewEventDish{
			ReviewEventID: parent.ID, DishID: dish.ID, Relation: models.DishReviewRelationAte,
		}).Error; err != nil {
			t.Fatal(err)
		}
	}
	parentID := parentWithDishScore.ID
	if err := h.db.Create(&models.CanteenDishReviewEvent{
		DishID: dish.ID, UserID: other.ID, TasteScore: 5, ValueScore: 3, PortionScore: 4,
		OverallScore: 4, Comment: "可选的菜品三维评分", Status: models.ReviewEventStatusActive,
		ScoreVersion: 1, CanteenReviewEventID: &parentID,
	}).Error; err != nil {
		t.Fatal(err)
	}

	response := performCanteenRequest(t, h.GetDishReviews, http.MethodGet,
		"/api/canteens/dishes/"+itoaForTest(dish.ID)+"/reviews",
		mapParams("dishId", itoaForTest(dish.ID)), 0, "")
	if response.Code != http.StatusOK {
		t.Fatalf("dish reviews status=%d body=%s", response.Code, response.Body.String())
	}
	var body struct {
		Items []map[string]interface{} `json:"items"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Items) != 2 {
		t.Fatalf("items=%+v", body.Items)
	}
	commentsByUser := make(map[uint]string, len(body.Items))
	for _, item := range body.Items {
		userID := uint(item["user_id"].(float64))
		commentsByUser[userID] = item["comment"].(string)
	}
	if commentsByUser[user.ID] != parentWithoutDishScore.Comment ||
		commentsByUser[other.ID] != parentWithDishScore.Comment {
		t.Fatalf("parent comments were not used: %+v", commentsByUser)
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

func TestReviewWithDishDirectlyCreatesActiveDishAndApprovedPhotos(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	file := createTestFile(t, h.db, 501, user.ID, models.FileAccessPrivate)

	response := performCanteenRequest(t, h.CreateReview, http.MethodPost,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID,
		fmt.Sprintf(`{"taste_score":5,"value_score":4,"queue_score":4,"hygiene_score":4,"service_score":4,"comment":"火锅牛肉米线超好吃","dishes":[{"dish_name":"火锅牛肉米线","photo_file_ids":[%d]}]}`, file.ID))
	if response.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", response.Code, response.Body.String())
	}

	var dish models.CanteenDish
	if err := h.db.Where("canteen_id = ? AND normalized_name = ?", canteen.ID, "火锅牛肉米线").First(&dish).Error; err != nil {
		t.Fatalf("dish not found: %v", err)
	}
	if dish.Status != models.DishStatusActive {
		t.Fatalf("dish status = %s, want active", dish.Status)
	}

	var photo models.CanteenDishPhoto
	if err := h.db.Where("dish_id = ? AND file_id = ?", dish.ID, file.ID).First(&photo).Error; err != nil {
		t.Fatalf("dish photo not found: %v", err)
	}
	if photo.Status != models.DishPhotoStatusApproved {
		t.Fatalf("photo status = %s, want approved", photo.Status)
	}

	var updatedFile models.File
	if err := h.db.First(&updatedFile, file.ID).Error; err != nil {
		t.Fatalf("file not found: %v", err)
	}
	if updatedFile.AccessScope != models.FileAccessPublic || updatedFile.Status != "active" {
		t.Fatalf("file access_scope = %s status = %s, want public active", updatedFile.AccessScope, updatedFile.Status)
	}
}

func TestReviewReusesExistingDish(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	existing := models.CanteenDish{
		CanteenID: canteen.ID, Name: "火锅牛肉米线", NormalizedName: "火锅牛肉米线",
		Status: models.DishStatusActive, CreatedBy: 1,
	}
	if err := h.db.Create(&existing).Error; err != nil {
		t.Fatal(err)
	}

	response := performCanteenRequest(t, h.CreateReview, http.MethodPost,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID,
		`{"taste_score":5,"value_score":4,"queue_score":4,"hygiene_score":4,"service_score":4,"comment":"再次打卡","dish_names":["火锅牛肉米线"]}`)
	if response.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", response.Code, response.Body.String())
	}

	var count int64
	h.db.Model(&models.CanteenDish{}).Where("canteen_id = ? AND normalized_name = ?", canteen.ID, "火锅牛肉米线").Count(&count)
	if count != 1 {
		t.Fatalf("expected 1 dish row, got %d", count)
	}
}

func TestMigratePendingDishesAndPhotosMigration(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	pendingDish := models.CanteenDish{
		CanteenID: canteen.ID, Name: "待审历史菜", NormalizedName: "待审历史菜",
		Status: models.DishStatusPending, CreatedBy: user.ID,
	}
	if err := h.db.Create(&pendingDish).Error; err != nil {
		t.Fatal(err)
	}
	file := createTestFile(t, h.db, 601, user.ID, models.FileAccessPrivate)
	pendingPhoto := models.CanteenDishPhoto{
		DishID: pendingDish.ID, FileID: file.ID, UserID: user.ID, Status: models.DishPhotoStatusPending,
	}
	if err := h.db.Create(&pendingPhoto).Error; err != nil {
		t.Fatal(err)
	}

	if err := models.MigratePendingDishesAndPhotos(h.db); err != nil {
		t.Fatalf("migration failed: %v", err)
	}

	var refreshedDish models.CanteenDish
	h.db.First(&refreshedDish, pendingDish.ID)
	if refreshedDish.Status != models.DishStatusActive {
		t.Fatalf("dish status after migration = %s, want active", refreshedDish.Status)
	}

	var refreshedPhoto models.CanteenDishPhoto
	h.db.First(&refreshedPhoto, pendingPhoto.ID)
	if refreshedPhoto.Status != models.DishPhotoStatusApproved {
		t.Fatalf("photo status after migration = %s, want approved", refreshedPhoto.Status)
	}

	var refreshedFile models.File
	h.db.First(&refreshedFile, file.ID)
	if refreshedFile.AccessScope != models.FileAccessPublic {
		t.Fatalf("file access after migration = %s, want public", refreshedFile.AccessScope)
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
