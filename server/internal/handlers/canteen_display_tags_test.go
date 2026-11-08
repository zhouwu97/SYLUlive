package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

func TestCanteenDisplayTagsDiscoveryLifecycle(t *testing.T) {
	db := newCanteenTestDB(t)
	createCanteenTestUser(t, db, 1, "管理员")
	createCanteenTestUser(t, db, 2, "评价者")
	shop := models.Canteen{Name: "测试店", NormalizedName: "测试店", Image: "/uploads/a", Verified: true, LocationArea: "一食堂", LocationFloor: "一楼"}
	if err := db.Create(&shop).Error; err != nil {
		t.Fatal(err)
	}
	rating := models.CanteenRating{CanteenID: shop.ID, UserID: 2, Star: 4, Tags: `["taste_good"]`, CreatedAt: time.Now()}
	if err := db.Create(&rating).Error; err != nil {
		t.Fatal(err)
	}
	h := NewCanteenHandler(db)
	canteenDiscoveryCache.Invalidate()
	t.Cleanup(canteenDiscoveryCache.Invalidate)
	params := gin.Params{{Key: "id", Value: fmt.Sprint(shop.ID)}}
	read := func() map[string]interface{} {
		resp := performCanteenRequest(t, h.GetRankings, http.MethodGet, "/", nil, 0, "")
		if resp.Code != 200 {
			t.Fatal(resp.Body.String())
		}
		var data struct {
			Items []map[string]interface{} `json:"items"`
		}
		if err := json.Unmarshal(resp.Body.Bytes(), &data); err != nil || len(data.Items) != 1 {
			t.Fatalf("rankings: %s", resp.Body.String())
		}
		return data.Items[0]
	}
	before := read()
	for _, step := range []struct{ tags, floor, wantTag string }{
		{`["clean","good_value"]`, "二楼", "clean"},
		{`[]`, "二楼", ""},
		{`null`, "一楼", "taste_good"},
	} {
		body := fmt.Sprintf(`{"location_area":"一食堂","location_floor":%q,"tags":%s}`, step.floor, step.tags)
		resp := performCanteenRequest(t, h.UpdateDisplayTags, http.MethodPut, "/", params, 1, body)
		if resp.Code != 200 {
			t.Fatal(resp.Body.String())
		}
		after := read()
		if after["location_floor"] != step.floor || after["ranking_score"] != before["ranking_score"] || after["rating_count"] != before["rating_count"] {
			t.Fatalf("unexpected discovery data: %+v", after)
		}
		tags, _ := after["summary_tags"].([]interface{})
		if step.wantTag == "" {
			if len(tags) != 0 {
				t.Fatal(tags)
			}
		} else if len(tags) == 0 || tags[0].(map[string]interface{})["key"] != step.wantTag {
			t.Fatal(tags)
		}
	}
	var stored models.CanteenRating
	if err := db.First(&stored, rating.ID).Error; err != nil || stored.Tags != rating.Tags || stored.Star != rating.Star {
		t.Fatal("original review changed", err)
	}
	var logs int64
	if err := db.Model(&models.AdminLog{}).Where("action = ?", "修改店铺标签").Count(&logs).Error; err != nil || logs != 3 {
		t.Fatalf("audit logs: %d %v", logs, err)
	}
}

func TestCanteenDisplayTagsMigrationIsCompatible(t *testing.T) {
	// newCanteenTestDB 只创建命名的内存 SQLite，不连接外部数据库。
	db := newCanteenTestDB(t)
	if err := db.Migrator().DropColumn(&models.Canteen{}, "display_tags"); err != nil {
		t.Fatal(err)
	}
	if err := db.Exec(`INSERT INTO canteens (id,name,normalized_name,image,verified,location_area,location_floor) VALUES (1,'旧店铺','旧店铺','/uploads/a',true,'一食堂','二楼')`).Error; err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := db.AutoMigrate(&models.Canteen{}); err != nil {
			t.Fatal(err)
		}
	}
	var shop models.Canteen
	if err := db.First(&shop, 1).Error; err != nil || shop.DisplayTags != nil || shop.LocationFloor != "二楼" {
		t.Fatalf("old data: %+v %v", shop, err)
	}
}

func TestCanteenDisplayTags(t *testing.T) {
	db := newCanteenTestDB(t)
	createCanteenTestUser(t, db, 1, "管理员")
	shop := models.Canteen{Name: "测试店", NormalizedName: "测试店", Image: "/uploads/a", Verified: true}
	if err := db.Create(&shop).Error; err != nil {
		t.Fatal(err)
	}
	h := NewCanteenHandler(db)
	params := gin.Params{{Key: "id", Value: fmt.Sprint(shop.ID)}}
	call := func(body string) int {
		return performCanteenRequest(t, h.UpdateDisplayTags, http.MethodPut, "/", params, 1, body).Code
	}
	for _, body := range []string{`{"location_area":"三食堂","location_floor":"一楼","tags":null}`, `{"location_area":"一食堂","location_floor":"一楼","tags":["unknown"]}`, `{"location_area":"一食堂","location_floor":"一楼","tags":["clean","clean"]}`, `{"location_area":"一食堂","location_floor":"一楼"}`} {
		if got := call(body); got != 400 {
			t.Fatalf("invalid input %s: %d", body, got)
		}
	}
	if got := call(`{"location_area":"一食堂","location_floor":"二楼","tags":["clean","good_value"]}`); got != 200 {
		t.Fatal(got)
	}
	tags, err := h.batchAggregateSummaryTags(30, 3)
	if err != nil || len(tags[shop.ID]) != 2 || tags[shop.ID][0].Name != "卫生干净" {
		t.Fatalf("override: %+v %v", tags, err)
	}
	var stored models.Canteen
	db.First(&stored, shop.ID)
	if stored.LocationFloor != "二楼" {
		t.Fatal(stored.LocationFloor)
	}
	resp := performCanteenRequest(t, h.GetDisplayTags, http.MethodGet, "/", params, 1, "")
	if !strings.Contains(resp.Body.String(), "good_value") {
		t.Fatal(resp.Body.String())
	}
	if got := call(`{"location_area":"","location_floor":"","tags":null}`); got != 200 {
		t.Fatal(got)
	}
	db.First(&stored, shop.ID)
	if stored.DisplayTags != nil {
		t.Fatal("automatic mode was not restored")
	}
	if got := performCanteenRequest(t, h.UpdateDisplayTags, http.MethodPut, "/", params, 0, `{"location_area":"","location_floor":"","tags":null}`).Code; got != 401 {
		t.Fatal(got)
	}
}

func TestDisplayTagsRequiresAdmin(t *testing.T) {
	db := newCanteenTestDB(t)
	h := NewCanteenHandler(db)
	r := gin.New()
	r.Use(func(c *gin.Context) { c.Set("role", "user"); c.Set("user_id", uint(1)); c.Next() })
	r.PUT("/:id/display-tags", middleware.AdminMiddleware(), h.UpdateDisplayTags)
	req := httptest.NewRequest(http.MethodPut, "/1/display-tags", strings.NewReader(`{"location_area":"","location_floor":"","tags":null}`))
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Fatalf("got %d", w.Code)
	}
}
