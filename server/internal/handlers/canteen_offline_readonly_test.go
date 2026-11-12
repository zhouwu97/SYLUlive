package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"

	"github.com/gin-gonic/gin"
	"shenliyuan/internal/models"
)

// 商家下架后，评价、图片、投票都只读：作者不能改也不能删，其他同学不能投票；
// 管理员的治理操作（隐藏菜品等）不受影响，恢复营业后一切照常。
func TestOfflineCanteenContentIsReadOnlyForUsers(t *testing.T) {
	h, canteen, author := prepareReviewV2DB(t)
	voter := createVerifiedUser(t, h.db, 901, "投票同学")
	created := performCanteenRequest(t, h.CreateReview, http.MethodPost, "/api/canteens/88/reviews", mapParams("id", "88"), author.ID,
		`{"taste_score":4,"value_score":4,"queue_score":4,"hygiene_score":4,"service_score":4,"comment":"原评价","dish_names":["卤肉饭"]}`)
	if created.Code != http.StatusCreated {
		t.Fatalf("create status=%d", created.Code)
	}
	var body struct {
		Review struct {
			ID uint `json:"id"`
		} `json:"review"`
	}
	_ = json.Unmarshal(created.Body.Bytes(), &body)
	reviewID := fmt.Sprint(body.Review.ID)
	legacy := models.CanteenRating{CanteenID: canteen.ID, UserID: voter.ID, Star: 4, Status: "active"}
	h.db.Create(&legacy)

	if resp := performCanteenRequest(t, h.OfflineCanteen, http.MethodPost, "/offline", mapParams("id", "88"), author.ID, `{"reason":"停业装修"}`); resp.Code != http.StatusOK {
		t.Fatalf("offline status=%d body=%s", resp.Code, resp.Body.String())
	}

	expectReadonly := func(name string, code int, raw []byte) {
		t.Helper()
		if code != http.StatusConflict || !containsReviewJSONCode(raw, "canteen_offline") || !containsString(raw, "仅供查看") {
			t.Fatalf("%s: status=%d body=%s", name, code, raw)
		}
	}
	update := performCanteenRequest(t, h.UpdateReview, http.MethodPatch, "/x", mapParams("reviewId", reviewID), author.ID,
		`{"taste_score":1,"value_score":1,"queue_score":1,"hygiene_score":1,"service_score":1,"comment":"改了"}`)
	expectReadonly("update", update.Code, update.Body.Bytes())
	del := performCanteenRequest(t, h.DeleteReview, http.MethodDelete, "/x", mapParams("reviewId", reviewID), author.ID, "")
	expectReadonly("delete", del.Code, del.Body.Bytes())
	delLegacy := performCanteenRequest(t, h.DeleteLegacyRating, http.MethodDelete, "/x", mapParams("ratingId", fmt.Sprint(legacy.ID)), voter.ID, "")
	expectReadonly("delete legacy", delLegacy.Code, delLegacy.Body.Bytes())
	vote := performCanteenRequest(t, h.VoteReview, http.MethodPut, "/x", mapParams("reviewId", reviewID), voter.ID, `{"vote":"up"}`)
	expectReadonly("vote", vote.Code, vote.Body.Bytes())
	voteLegacy := performCanteenRequest(t, h.VoteRating, http.MethodPut, "/x", mapParams("ratingId", fmt.Sprint(legacy.ID)), author.ID, `{"vote":"up"}`)
	expectReadonly("vote legacy", voteLegacy.Code, voteLegacy.Body.Bytes())

	var stored models.CanteenReviewEvent
	h.db.First(&stored, body.Review.ID)
	if stored.Comment != "原评价" || stored.Status != models.ReviewEventStatusActive {
		t.Fatalf("offline review must stay untouched: %+v", stored)
	}

	// 管理员治理不受下架影响。
	var dish models.CanteenDish
	h.db.Where("canteen_id = ?", canteen.ID).First(&dish)
	hide := performDishPhotoRequest(t, NewCanteenDishPhotoAdminHandler(h.db).AdminUpdateDish, http.MethodPatch, "/x",
		gin.Params{{Key: "dishId", Value: fmt.Sprint(dish.ID)}}, author.ID, `{"status":"hidden"}`)
	if hide.Code != http.StatusOK {
		t.Fatalf("admin hide on offline shop status=%d body=%s", hide.Code, hide.Body.String())
	}

	// 恢复营业后作者可以再修改。
	if resp := performCanteenRequest(t, h.OnlineCanteen, http.MethodPost, "/online", mapParams("id", "88"), author.ID, ""); resp.Code != http.StatusOK {
		t.Fatalf("online status=%d", resp.Code)
	}
	again := performCanteenRequest(t, h.VoteReview, http.MethodPut, "/x", mapParams("reviewId", reviewID), voter.ID, `{"vote":"up"}`)
	if again.Code != http.StatusOK {
		t.Fatalf("vote after online status=%d body=%s", again.Code, again.Body.String())
	}
}
