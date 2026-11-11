package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"shenliyuan/internal/models"
)

func seedDishWithPhotos(t *testing.T, h *CanteenHandler, canteenID, userID uint, name string, photos int) models.CanteenDish {
	t.Helper()
	dish := models.CanteenDish{CanteenID: canteenID, Name: name, NormalizedName: name, Status: models.DishStatusActive, CreatedBy: userID}
	if err := h.db.Create(&dish).Error; err != nil {
		t.Fatal(err)
	}
	base := time.Now().Add(-time.Hour)
	for i := 0; i < photos; i++ {
		file := models.File{Hash: fmt.Sprintf("%s-%d", name, i), Path: fmt.Sprintf("/uploads/%s-%d.jpg", name, i), Size: 1, MimeType: "image/jpeg", UploaderID: userID, Status: "active", AccessScope: models.FileAccessPublic}
		if err := h.db.Create(&file).Error; err != nil {
			t.Fatal(err)
		}
		if err := h.db.Create(&models.CanteenDishPhoto{DishID: dish.ID, FileID: file.ID, UserID: userID, Status: models.DishPhotoStatusApproved,
			CreatedAt: base.Add(time.Duration(i) * time.Minute)}).Error; err != nil {
			t.Fatal(err)
		}
	}
	return dish
}

type dishDetailBody struct {
	PhotoCount int `json:"photo_count"`
	Photos     []struct {
		ID    uint   `json:"id"`
		Image string `json:"image"`
	} `json:"photos"`
	Scores struct {
		Average float64 `json:"average"`
		Taste   float64 `json:"taste"`
		Portion float64 `json:"portion"`
	} `json:"scores"`
	RatedCount int `json:"rated_count"`
}

func getDishDetail(t *testing.T, h *CanteenHandler, dishID uint) dishDetailBody {
	t.Helper()
	resp := performDishPhotoRequest(t, NewCanteenDishHandler(h.db).GetDish, http.MethodGet, "/api/canteens/88/dishes",
		gin.Params{{Key: "id", Value: "88"}, {Key: "dishId", Value: fmt.Sprint(dishID)}}, 0, "")
	if resp.Code != http.StatusOK {
		t.Fatalf("dish status=%d body=%s", resp.Code, resp.Body.String())
	}
	var body dishDetailBody
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	return body
}

func TestDishDetailShowsScoresAndNewestPhotosWithPinnedCover(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	dish := seedDishWithPhotos(t, h, canteen.ID, user.ID, "烤冷面", 8)

	// 通过评价给菜打三维分：味道5 性价比4 分量3。
	review := performCanteenRequest(t, h.CreateReview, http.MethodPost, "/api/canteens/88/reviews", mapParams("id", "88"), user.ID,
		fmt.Sprintf(`{"taste_score":5,"value_score":4,"queue_score":3,"hygiene_score":4,"service_score":4,"dishes":[{"dish_id":%d,"taste_score":5,"value_score":4,"portion_score":3}]}`, dish.ID))
	if review.Code != http.StatusCreated {
		t.Fatalf("review status=%d body=%s", review.Code, review.Body.String())
	}

	body := getDishDetail(t, h, dish.ID)
	if body.RatedCount != 1 || body.Scores.Taste != 5 || body.Scores.Portion != 3 || body.Scores.Average <= 0 {
		t.Fatalf("scores=%+v rated=%d", body.Scores, body.RatedCount)
	}
	if body.PhotoCount != 8 || len(body.Photos) != dishPhotoDisplayLimit || body.Photos[0].Image != "/uploads/烤冷面-7.jpg" {
		t.Fatalf("photo_count=%d photos=%+v want newest 6 of 8", body.PhotoCount, body.Photos)
	}

	// 管理员把最旧的一张设为封面：详情第一张和热门菜品封面都跟着变。
	var oldest models.CanteenDishPhoto
	h.db.Where("dish_id = ?", dish.ID).Order("created_at ASC").First(&oldest)
	cover := performDishPhotoRequest(t, NewCanteenDishPhotoAdminHandler(h.db).SetDishPhotoCover, http.MethodPost, "/cover",
		gin.Params{{Key: "photoId", Value: fmt.Sprint(oldest.ID)}}, user.ID, "")
	if cover.Code != http.StatusOK {
		t.Fatalf("cover status=%d body=%s", cover.Code, cover.Body.String())
	}
	if first := getDishDetail(t, h, dish.ID).Photos[0].ID; first != oldest.ID {
		t.Fatalf("pinned cover not first: got photo %d want %d", first, oldest.ID)
	}
	hot := h.hotDishes(4)
	if len(hot) != 1 || hot[0].CoverImage != "/uploads/烤冷面-0.jpg" || hot[0].ReviewerCount != 1 {
		t.Fatalf("hot dishes=%+v", hot)
	}
}

func TestDishReviewsOptionalPaging(t *testing.T) {
	h, canteen, _ := prepareReviewV2DB(t)
	dish := seedDishWithPhotos(t, h, canteen.ID, 88, "肉夹馍", 0)
	for i := 0; i < 5; i++ {
		u := createVerifiedUser(t, h.db, uint(600+i), fmt.Sprintf("食客%d", i))
		resp := performCanteenRequest(t, h.CreateReview, http.MethodPost, "/api/canteens/88/reviews", mapParams("id", "88"), u.ID,
			fmt.Sprintf(`{"taste_score":4,"value_score":4,"queue_score":4,"hygiene_score":4,"service_score":4,"dish_ids":[%d]}`, dish.ID))
		if resp.Code != http.StatusCreated {
			t.Fatalf("review %d status=%d body=%s", i, resp.Code, resp.Body.String())
		}
	}
	list := func(query string) (int, map[string]interface{}) {
		resp := performCanteenRequest(t, h.GetDishReviews, http.MethodGet, "/api/canteens/dishes/reviews"+query,
			mapParams("dishId", fmt.Sprint(dish.ID)), 0, "")
		var body map[string]interface{}
		_ = json.Unmarshal(resp.Body.Bytes(), &body)
		return resp.Code, body
	}
	if code, body := list(""); code != http.StatusOK || body["count"].(float64) != 5 || body["has_more"] != nil {
		t.Fatalf("unpaged status=%d body=%v", code, body)
	}
	if code, body := list("?limit=2&offset=2"); code != http.StatusOK || body["count"].(float64) != 2 || body["has_more"] != true || body["total"].(float64) != 5 {
		t.Fatalf("page 2 status=%d body=%v", code, body)
	}
	if _, body := list("?limit=2&offset=4"); body["count"].(float64) != 1 || body["has_more"] != false {
		t.Fatalf("last page body=%v", body)
	}
	if code, _ := list("?limit=0"); code != http.StatusBadRequest {
		t.Fatalf("limit=0 status=%d", code)
	}
}

func TestMergeMovesEveryApprovedPhoto(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	source := seedDishWithPhotos(t, h, canteen.ID, user.ID, "番茄炒蛋", 3)
	target := seedDishWithPhotos(t, h, canteen.ID, user.ID, "西红柿炒鸡蛋", 3)
	resp := performDishPhotoRequest(t, NewCanteenDishPhotoAdminHandler(h.db).AdminMergeDish, http.MethodPost, "/merge",
		gin.Params{{Key: "dishId", Value: fmt.Sprint(source.ID)}}, user.ID, fmt.Sprintf(`{"target_dish_id":%d}`, target.ID))
	if resp.Code != http.StatusOK {
		t.Fatalf("merge status=%d body=%s", resp.Code, resp.Body.String())
	}
	var approved int64
	h.db.Model(&models.CanteenDishPhoto{}).Where("dish_id = ? AND status = ?", target.ID, models.DishPhotoStatusApproved).Count(&approved)
	if approved != 6 {
		t.Fatalf("approved photos on target=%d want 6 (no 3-photo cap)", approved)
	}
}

// 一顿饭吃了两样：一条评价关联两道菜，各自打分、各自绑定实拍，第 4 道被拒绝。
func TestReviewCanLinkUpToThreeDishesWithSeparateScoresAndPhotos(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	noodles := seedDishWithPhotos(t, h, canteen.ID, user.ID, "牛肉面", 0)
	fileA := createTestFile(t, h.db, 9001, user.ID, models.FileAccessPrivate)
	fileB := createTestFile(t, h.db, 9002, user.ID, models.FileAccessPrivate)
	body := fmt.Sprintf(`{"taste_score":5,"value_score":4,"queue_score":3,"hygiene_score":4,"service_score":4,
		"dish_ids":[%d],"dish_names":["卤蛋"],
		"dishes":[{"dish_id":%d,"taste_score":5,"value_score":4,"portion_score":5,"photo_file_ids":[%d]},
		          {"dish_name":"卤蛋","taste_score":3,"value_score":3,"portion_score":2,"photo_file_ids":[%d]}]}`,
		noodles.ID, noodles.ID, fileA.ID, fileB.ID)
	resp := performCanteenRequest(t, h.CreateReview, http.MethodPost, "/api/canteens/88/reviews", mapParams("id", "88"), user.ID, body)
	if resp.Code != http.StatusCreated {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var egg models.CanteenDish
	if err := h.db.Where("canteen_id = ? AND name = ?", canteen.ID, "卤蛋").First(&egg).Error; err != nil {
		t.Fatalf("new dish not created: %v", err)
	}
	if got := getDishDetail(t, h, noodles.ID); got.Scores.Portion != 5 || got.PhotoCount != 1 {
		t.Fatalf("noodles=%+v", got)
	}
	resp = performDishPhotoRequest(t, NewCanteenDishHandler(h.db).GetDish, http.MethodGet, "/x",
		gin.Params{{Key: "id", Value: "88"}, {Key: "dishId", Value: fmt.Sprint(egg.ID)}}, 0, "")
	var eggBody dishDetailBody
	_ = json.Unmarshal(resp.Body.Bytes(), &eggBody)
	if eggBody.Scores.Portion != 2 || eggBody.PhotoCount != 1 {
		t.Fatalf("egg=%+v", eggBody)
	}

	tooMany := performCanteenRequest(t, h.CreateReview, http.MethodPost, "/api/canteens/88/reviews", mapParams("id", "88"), user.ID,
		`{"taste_score":5,"value_score":4,"queue_score":3,"hygiene_score":4,"service_score":4,"dish_names":["一","二","三","四"]}`)
	if tooMany.Code != http.StatusBadRequest || !containsReviewJSONCode(tooMany.Body.Bytes(), "invalid_review_dish") {
		t.Fatalf("4 dishes status=%d body=%s", tooMany.Code, tooMany.Body.String())
	}
}

// “热门”看最近：近 30 天被提到更多的菜排在历史打分人数更多的菜前面，并能分页拉取。
func TestHotDishesPreferRecentMentionsAndPage(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	oldFavorite := seedDishWithPhotos(t, h, canteen.ID, user.ID, "老招牌", 1)
	newHit := seedDishWithPhotos(t, h, canteen.ID, user.ID, "新网红", 1)
	seedDishWithPhotos(t, h, canteen.ID, user.ID, "冷门菜", 1)
	longAgo := time.Now().AddDate(0, -3, 0)
	for i := 0; i < 3; i++ {
		u := createVerifiedUser(t, h.db, uint(800+i), fmt.Sprintf("老客%d", i))
		event := models.CanteenReviewEvent{CanteenID: canteen.ID, UserID: u.ID, TasteScore: 4, ValueScore: 4, QueueScore: 4,
			HygieneScore: 4, ServiceScore: 4, OverallScore: 4, Status: models.ReviewEventStatusActive, ScoreVersion: 2, CreatedAt: longAgo}
		h.db.Create(&event)
		h.db.Create(&models.CanteenReviewEventDish{ReviewEventID: event.ID, DishID: oldFavorite.ID, Relation: models.DishReviewRelationAte})
		h.db.Create(&models.CanteenDishRatingSummary{DishID: oldFavorite.ID, UserID: u.ID, EffectiveScore: 4, TasteScore: 4, ValueScore: 4, PortionScore: 4})
	}
	recentUser := createVerifiedUser(t, h.db, 900, "新客")
	resp := performCanteenRequest(t, h.CreateReview, http.MethodPost, "/api/canteens/88/reviews", mapParams("id", "88"), recentUser.ID,
		fmt.Sprintf(`{"taste_score":4,"value_score":4,"queue_score":4,"hygiene_score":4,"service_score":4,"dish_ids":[%d]}`, newHit.ID))
	if resp.Code != http.StatusCreated {
		t.Fatalf("review status=%d", resp.Code)
	}

	hot := h.hotDishes(0)
	if len(hot) != 3 || hot[0].ID != newHit.ID || hot[0].RecentMentionCount != 1 || hot[1].ID != oldFavorite.ID {
		t.Fatalf("hot order=%+v", hot)
	}
	page := performCanteenRequest(t, h.GetHotDishes, http.MethodGet, "/api/canteens/dishes/hot?limit=2&offset=2", nil, 0, "")
	var body struct {
		Items   []canteenHotDishItem `json:"items"`
		Total   int                  `json:"total"`
		HasMore bool                 `json:"has_more"`
	}
	_ = json.Unmarshal(page.Body.Bytes(), &body)
	if page.Code != http.StatusOK || body.Total != 3 || len(body.Items) != 1 || body.HasMore || body.Items[0].Name != "冷门菜" {
		t.Fatalf("page status=%d body=%s", page.Code, page.Body.String())
	}
}
