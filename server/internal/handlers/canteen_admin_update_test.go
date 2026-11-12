package handlers

import (
	"net/http"
	"testing"

	"shenliyuan/internal/models"
)

func TestAdminUpdateCanteenNameAndLocation(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	other := models.Canteen{Name: "麻辣烫", NormalizedName: "麻辣烫", LocationArea: models.CanteenLocationArea2,
		LocationFloor: models.CanteenLocationFloor1, Image: "/uploads/x.png", CreatedBy: user.ID, Verified: true}
	if err := h.db.Create(&other).Error; err != nil {
		t.Fatal(err)
	}
	// 先发一条评价，确认改名不会动到历史评价。
	if resp := performCanteenRequest(t, h.CreateReview, http.MethodPost, "/api/canteens/88/reviews",
		mapParams("id", "88"), user.ID, reviewBody()); resp.Code != http.StatusCreated {
		t.Fatalf("review status=%d", resp.Code)
	}

	ok := performCanteenRequest(t, h.AdminUpdateCanteen, http.MethodPatch, "/api/canteens/88",
		mapParams("id", "88"), user.ID, `{"name":"  兰州拉面  ","location_area":"一食堂","location_floor":"二楼"}`)
	if ok.Code != http.StatusOK {
		t.Fatalf("update status=%d body=%s", ok.Code, ok.Body.String())
	}
	var updated models.Canteen
	h.db.First(&updated, canteen.ID)
	if updated.Name != "兰州拉面" || updated.NormalizedName != "兰州拉面" ||
		updated.LocationArea != models.CanteenLocationArea1 || updated.LocationFloor != models.CanteenLocationFloor2 {
		t.Fatalf("updated=%+v", updated)
	}
	var events int64
	h.db.Model(&models.CanteenReviewEvent{}).Where("canteen_id = ?", canteen.ID).Count(&events)
	if events != 1 {
		t.Fatalf("review events=%d want 1", events)
	}
	var logs int64
	h.db.Model(&models.AdminLog{}).Where("action = ?", "修改食堂信息").Count(&logs)
	if logs != 1 {
		t.Fatalf("admin logs=%d want 1", logs)
	}

	// 只改位置，撞上同位置同名商家 → 409。
	conflict := performCanteenRequest(t, h.AdminUpdateCanteen, http.MethodPatch, "/api/canteens/88",
		mapParams("id", "88"), user.ID, `{"name":"麻辣烫","location_area":"二食堂","location_floor":"一楼"}`)
	if conflict.Code != http.StatusConflict {
		t.Fatalf("conflict status=%d body=%s", conflict.Code, conflict.Body.String())
	}
	for _, body := range []string{`{}`, `{"name":"a"}`, `{"location_area":"三食堂"}`, `{"location_floor":"九楼"}`} {
		if resp := performCanteenRequest(t, h.AdminUpdateCanteen, http.MethodPatch, "/api/canteens/88",
			mapParams("id", "88"), user.ID, body); resp.Code != http.StatusBadRequest {
			t.Fatalf("body %s status=%d want 400", body, resp.Code)
		}
	}
	if resp := performCanteenRequest(t, h.AdminUpdateCanteen, http.MethodPatch, "/api/canteens/999",
		mapParams("id", "999"), user.ID, `{"name":"不存在的店"}`); resp.Code != http.StatusNotFound {
		t.Fatalf("missing status=%d", resp.Code)
	}
}

func TestAdminListCanteensShowsOfflineReason(t *testing.T) {
	h, _, user := prepareReviewV2DB(t)
	other := models.Canteen{Name: "麻辣烫", NormalizedName: "麻辣烫", Image: "/uploads/m.png", CreatedBy: user.ID, Verified: true}
	h.db.Create(&other)
	if resp := performCanteenRequest(t, h.OfflineCanteen, http.MethodPost, "/offline", mapParams("id", "88"), user.ID, `{"reason":"档口转让"}`); resp.Code != http.StatusOK {
		t.Fatalf("offline status=%d", resp.Code)
	}
	resp := performCanteenRequest(t, h.AdminListCanteens, http.MethodGet, "/api/canteens/admin-list", nil, user.ID, "")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d", resp.Code)
	}
	body := resp.Body.String()
	if !containsString(resp.Body.Bytes(), `"offline_reason":"档口转让"`) || !containsString(resp.Body.Bytes(), `"active_count":1`) ||
		!containsString(resp.Body.Bytes(), `"offline_count":1`) {
		t.Fatalf("body=%s", body)
	}
}
