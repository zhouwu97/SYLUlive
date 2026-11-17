package handlers

import (
	"fmt"
	"net/http"
	"testing"

	"shenliyuan/internal/models"
)

func TestAdminUnifiedCanteenUpdateIsAtomicAndCompatible(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	params := mapParams("id", fmt.Sprint(canteen.ID))
	call := func(body string) int {
		return performCanteenRequest(t, h.AdminUpdateCanteen, http.MethodPatch, "/", params, user.ID, body).Code
	}
	read := func() models.Canteen {
		var stored models.Canteen
		if err := h.db.First(&stored, canteen.ID).Error; err != nil {
			t.Fatal(err)
		}
		return stored
	}
	if got := call(`{"name":"校外小馆","location_area":"其他","location_floor":"","tags":["clean","good_value"]}`); got != 200 {
		t.Fatalf("unified update: %d", got)
	}
	stored := read()
	if stored.Name != "校外小馆" || stored.LocationArea != "其他" || stored.LocationFloor != "" ||
		stored.DisplayTags == nil || *stored.DisplayTags != `["clean","good_value"]` {
		t.Fatalf("stored: %+v", stored)
	}
	// 无效标签或位置冲突必须回滚名称、位置、标签整组字段。
	for _, tags := range []string{`["unknown"]`, `["clean","clean"]`, `["clean","good_value","taste_good","queue_long"]`, `{}`, `"clean"`} {
		if got := call(`{"name":"不能部分保存","location_area":"一食堂","tags":` + tags + `}`); got != 400 {
			t.Fatalf("invalid tags %s: %d", tags, got)
		}
		if after := read(); after.Name != stored.Name || after.LocationArea != stored.LocationArea || *after.DisplayTags != *stored.DisplayTags {
			t.Fatalf("partial write: %+v", after)
		}
	}
	other := models.Canteen{Name: "位置冲突", NormalizedName: "位置冲突", LocationArea: "其他", Image: "/uploads/a.png", Verified: true, CreatedBy: user.ID}
	if err := h.db.Create(&other).Error; err != nil {
		t.Fatal(err)
	}
	if got := call(`{"name":"位置冲突","location_area":"其他","location_floor":"","tags":[]}`); got != 409 {
		t.Fatal(got)
	}
	if after := read(); after.Name != stored.Name || *after.DisplayTags != *stored.DisplayTags {
		t.Fatal("conflict partially saved")
	}
	// 旧客户端不传 tags 时保留设置；null 自动汇总，[] 隐藏。
	if got := call(`{"name":"旧端改名"}`); got != 200 {
		t.Fatal(got)
	}
	if after := read(); after.DisplayTags == nil || *after.DisplayTags != *stored.DisplayTags {
		t.Fatal("legacy update erased tags")
	}
	if got := call(`{"tags":null}`); got != 200 {
		t.Fatal(got)
	}
	if read().DisplayTags != nil {
		t.Fatal("null must restore automatic aggregation")
	}
	if got := call(`{"tags":[]}`); got != 200 {
		t.Fatal(got)
	}
	if after := read(); after.DisplayTags == nil || *after.DisplayTags != `[]` {
		t.Fatal("empty array must hide tags")
	}
}

func TestOtherCanteenSubmissionAndDiscovery(t *testing.T) {
	h, _, user := prepareReviewV2DB(t)
	file := models.File{Hash: "other-shop", Path: "/uploads/other-shop.png", Size: 1, MimeType: "image/png", UploaderID: user.ID, Status: "active"}
	if err := h.db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	resp := performCanteenRequest(t, h.Create, http.MethodPost, "/", nil, user.ID,
		`{"name":"校外餐饮","image":"/uploads/other-shop.png","location_area":"其他","location_floor":""}`)
	if resp.Code != 201 {
		t.Fatalf("create: %d %s", resp.Code, resp.Body.String())
	}
	var shop models.Canteen
	if err := h.db.Where("name = ?", "校外餐饮").First(&shop).Error; err != nil {
		t.Fatal(err)
	}
	if shop.Verified || shop.LocationArea != "其他" || shop.LocationFloor != "" {
		t.Fatalf("shop: %+v", shop)
	}
	params := mapParams("id", fmt.Sprint(shop.ID))
	resp = performCanteenRequest(t, h.ApproveCanteen, http.MethodPost, "/", params, user.ID, "")
	if resp.Code != 200 {
		t.Fatalf("approve: %d %s", resp.Code, resp.Body.String())
	}
	resp = performCanteenRequest(t, h.GetList, http.MethodGet, "/", nil, 0, "")
	if resp.Code != 200 || !containsString(resp.Body.Bytes(), `"location_area":"其他"`) {
		t.Fatalf("list: %s", resp.Body.String())
	}
}

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
