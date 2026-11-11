package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"

	"github.com/gin-gonic/gin"
	"shenliyuan/internal/models"
)

// 管理员把“番茄炒蛋”改名为“西红柿炒鸡蛋”后，同学再输入旧名要落到同一道菜，
// 不能重新长出一道重复菜。
func TestAdminRenameKeepsOldNameAsAliasForReviews(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	dish := models.CanteenDish{CanteenID: canteen.ID, Name: "番茄炒蛋", NormalizedName: "番茄炒蛋", Status: models.DishStatusActive, CreatedBy: user.ID}
	if err := h.db.Create(&dish).Error; err != nil {
		t.Fatal(err)
	}
	admin := NewCanteenDishPhotoAdminHandler(h.db)
	rename := performDishPhotoRequest(t, admin.AdminUpdateDish, http.MethodPatch,
		fmt.Sprintf("/api/canteens/dishes/%d", dish.ID),
		gin.Params{{Key: "dishId", Value: fmt.Sprint(dish.ID)}}, user.ID, `{"name":"西红柿炒鸡蛋"}`)
	if rename.Code != http.StatusOK {
		t.Fatalf("rename status=%d body=%s", rename.Code, rename.Body.String())
	}

	review := performCanteenRequest(t, h.CreateReview, http.MethodPost, "/api/canteens/88/reviews",
		mapParams("id", "88"), user.ID,
		`{"taste_score":5,"value_score":4,"queue_score":3,"hygiene_score":4,"service_score":4,"dish_names":["番茄炒蛋"]}`)
	if review.Code != http.StatusCreated {
		t.Fatalf("review status=%d body=%s", review.Code, review.Body.String())
	}
	var dishCount int64
	h.db.Model(&models.CanteenDish{}).Where("canteen_id = ?", canteen.ID).Count(&dishCount)
	if dishCount != 1 {
		t.Fatalf("dish count=%d want 1 (old name must resolve via alias)", dishCount)
	}
	var relation models.CanteenReviewEventDish
	if err := h.db.Where("dish_id = ?", dish.ID).First(&relation).Error; err != nil {
		t.Fatalf("review must link to renamed dish: %v", err)
	}

	// 隐藏后旧名不能再静默指向它，也不能新建同名菜。
	hide := performDishPhotoRequest(t, admin.AdminUpdateDish, http.MethodPatch,
		fmt.Sprintf("/api/canteens/dishes/%d", dish.ID),
		gin.Params{{Key: "dishId", Value: fmt.Sprint(dish.ID)}}, user.ID, `{"status":"hidden"}`)
	if hide.Code != http.StatusOK {
		t.Fatalf("hide status=%d", hide.Code)
	}
	again := performCanteenRequest(t, h.CreateReview, http.MethodPost, "/api/canteens/88/reviews",
		mapParams("id", "88"), user.ID,
		`{"taste_score":5,"value_score":4,"queue_score":3,"hygiene_score":4,"service_score":4,"dish_names":["番茄炒蛋"]}`)
	if again.Code != http.StatusConflict || !containsReviewJSONCode(again.Body.Bytes(), "review_dish_conflict") {
		t.Fatalf("hidden alias status=%d body=%s", again.Code, again.Body.String())
	}
}

func TestAdminListDishesIncludesHiddenButNotMerged(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	seed := func(name, status string) models.CanteenDish {
		dish := models.CanteenDish{CanteenID: canteen.ID, Name: name, NormalizedName: name, Status: status, CreatedBy: user.ID}
		if err := h.db.Create(&dish).Error; err != nil {
			t.Fatal(err)
		}
		return dish
	}
	seed("隐藏菜", models.DishStatusHidden)
	seed("上架菜", models.DishStatusActive)
	seed("已合并菜", models.DishStatusMerged)

	resp := performDishPhotoRequest(t, NewCanteenDishPhotoAdminHandler(h.db).AdminListDishes, http.MethodGet,
		"/api/canteens/88/admin-dishes", gin.Params{{Key: "id", Value: "88"}}, user.ID, "")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var body struct {
		Items []struct {
			Name   string `json:"name"`
			Status string `json:"status"`
		} `json:"items"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Items) != 2 || body.Items[0].Name != "上架菜" || body.Items[1].Status != models.DishStatusHidden {
		t.Fatalf("items=%+v want active first then hidden, merged excluded", body.Items)
	}
	missing := performDishPhotoRequest(t, NewCanteenDishPhotoAdminHandler(h.db).AdminListDishes, http.MethodGet,
		"/api/canteens/999/admin-dishes", gin.Params{{Key: "id", Value: "999"}}, user.ID, "")
	if missing.Code != http.StatusNotFound {
		t.Fatalf("missing canteen status=%d", missing.Code)
	}
}
