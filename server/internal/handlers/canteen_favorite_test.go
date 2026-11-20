package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"

	"github.com/gin-gonic/gin"
	"shenliyuan/internal/models"
)

func TestCanteenFavoriteLifecycle(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	other := models.Canteen{Name: "麻辣烫", NormalizedName: "麻辣烫", Image: "/uploads/m.png", CreatedBy: user.ID, Verified: true}
	pending := models.Canteen{Name: "待审店", NormalizedName: "待审店", Image: "/uploads/p.png", CreatedBy: user.ID}
	h.db.Create(&other)
	h.db.Create(&pending)
	call := func(handler gin.HandlerFunc, method string, id uint) int {
		return performCanteenRequest(t, handler, method, "/api/user/canteen-favorites",
			mapParams("id", fmt.Sprint(id)), user.ID, "").Code
	}
	listNames := func() []string {
		resp := performCanteenRequest(t, h.ListFavorites, http.MethodGet, "/api/user/canteen-favorites", nil, user.ID, "")
		var body struct {
			Items []struct {
				Name string `json:"name"`
			} `json:"items"`
		}
		_ = json.Unmarshal(resp.Body.Bytes(), &body)
		names := []string{}
		for _, item := range body.Items {
			names = append(names, item.Name)
		}
		return names
	}

	if code := call(h.AddFavorite, http.MethodPut, canteen.ID); code != http.StatusOK {
		t.Fatalf("add status=%d", code)
	}
	if code := call(h.AddFavorite, http.MethodPut, canteen.ID); code != http.StatusOK {
		t.Fatalf("repeat add should be idempotent, status=%d", code)
	}
	if code := call(h.AddFavorite, http.MethodPut, other.ID); code != http.StatusOK {
		t.Fatalf("add other status=%d", code)
	}
	if code := call(h.AddFavorite, http.MethodPut, pending.ID); code != http.StatusNotFound {
		t.Fatalf("pending shop must not be favoritable, status=%d", code)
	}
	if got := listNames(); len(got) != 2 {
		t.Fatalf("favorites=%v", got)
	}

	detail := performCanteenRequest(t, h.GetDetail, http.MethodGet, "/api/canteens/88?compact=1", mapParams("id", "88"), user.ID, "")
	if !containsString(detail.Body.Bytes(), `"is_favorite":true`) {
		t.Fatalf("detail must report is_favorite for the viewer")
	}
	anonymous := performCanteenRequest(t, h.GetDetail, http.MethodGet, "/api/canteens/88?compact=1", mapParams("id", "88"), 0, "")
	if !containsString(anonymous.Body.Bytes(), `"is_favorite":false`) {
		t.Fatalf("anonymous detail must report is_favorite=false")
	}

	if code := call(h.RemoveFavorite, http.MethodDelete, canteen.ID); code != http.StatusOK {
		t.Fatalf("remove status=%d", code)
	}
	if code := call(h.RemoveFavorite, http.MethodDelete, canteen.ID); code != http.StatusOK {
		t.Fatalf("repeat remove should be idempotent, status=%d", code)
	}
	if got := fmt.Sprint(listNames()); got != "[麻辣烫]" {
		t.Fatalf("favorites after remove=%s", got)
	}
}

// 收藏是个人数据：导出时要包含，注销账号时要删除。
func TestCanteenFavoritesExportedAndDeletedOnAccountCancel(t *testing.T) {
	handler, db, user := newPrivacyTestHandler(t)
	if err := db.AutoMigrate(&models.CanteenFavorite{}); err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenFavorite{UserID: user.ID, CanteenID: 7}).Error; err != nil {
		t.Fatal(err)
	}
	payload, err := handler.personalDataPayload(user.ID, false)
	if err != nil {
		t.Fatal(err)
	}
	if favorites, ok := payload["canteen_favorites"].([]models.CanteenFavorite); !ok || len(favorites) != 1 {
		t.Fatalf("export must include canteen favorites: %#v", payload["canteen_favorites"])
	}
	context, recorder := privacyContext(http.MethodDelete, "/api/user/account", `{"password":"password123","confirmed":true}`, user.ID)
	handler.CancelAccount(context)
	if recorder.Code != http.StatusOK {
		t.Fatalf("cancel status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var remaining int64
	db.Model(&models.CanteenFavorite{}).Where("user_id = ?", user.ID).Count(&remaining)
	if remaining != 0 {
		t.Fatalf("favorites must be deleted on account cancel, remaining=%d", remaining)
	}
}
