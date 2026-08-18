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
	if err := db.AutoMigrate(&models.WaterTeamRecruitment{}, &models.WaterTeamApplication{},
		&models.User{},
		&models.File{},
		&models.FileUploadGrant{},
		&models.Canteen{},
		&models.CanteenRating{},
		&models.CanteenRatingVote{},
		&models.CanteenDish{},
		&models.CanteenDishPhoto{},
		&models.CanteenRatingDishRecommendation{},
		&models.AdminLog{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	// 与生产 EnsureRatingInteractionSchema 对齐：建立 (canteen_id,user_id) 唯一约束，
	// 使 Rate 的 ON CONFLICT upsert 在 SQLite 测试库中同样生效。
	if err := db.Exec(`
		CREATE UNIQUE INDEX IF NOT EXISTS uq_canteen_rating_user
		ON canteen_ratings (canteen_id, user_id)
	`).Error; err != nil {
		t.Fatalf("create canteen rating unique index: %v", err)
	}
	if err := models.EnsureCanteenRatingRecommendationSchema(db); err != nil {
		t.Fatalf("create canteen rating recommendation index: %v", err)
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
	if userID != 0 {
		context.Set("user_id", userID)
	}
	handler(context)
	return recorder
}

func TestCanteenVoteRatingTogglesAndReturnsCounts(t *testing.T) {
	db := newCanteenTestDB(t)
	createCanteenTestUser(t, db, 1, "Alice")
	createCanteenTestUser(t, db, 2, "Bob")
	canteen := models.Canteen{Name: "外卖", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
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
	canteen := models.Canteen{Name: "外卖", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
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
	createCanteenTestUser(t, db, 4, "David")
	createCanteenTestUser(t, db, 5, "Eve")
	canteen := models.Canteen{Name: "外卖", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatalf("create canteen: %v", err)
	}
	// (canteen_id,user_id) 唯一约束下，每个用户只能一条评价。
	ratings := []models.CanteenRating{
		{CanteenID: canteen.ID, UserID: 2, Star: 5, Comment: "   ", HelpfulCount: 10},
		{CanteenID: canteen.ID, UserID: 3, Star: 4, Comment: "有参考价值", Images: `["/uploads/a.png"]`, HelpfulCount: 5},
		{CanteenID: canteen.ID, UserID: 4, Star: 4, Comment: "   ", HelpfulCount: 5},
		{CanteenID: canteen.ID, UserID: 5, Star: 1, Comment: "踩雷", UnhelpfulCount: 1},
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

	anonymous := performCanteenRequest(
		t,
		handler.GetDetail,
		http.MethodGet,
		fmt.Sprintf("/api/canteens/%d", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
		0,
		"",
	)
	if anonymous.Code != http.StatusOK {
		t.Fatalf("anonymous detail status=%d body=%s", anonymous.Code, anonymous.Body.String())
	}
	if !strings.Contains(anonymous.Body.String(), `"my_rating":null`) {
		t.Fatalf("anonymous detail must not expose a personal rating: %s", anonymous.Body.String())
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

func TestCanteenApprovalControlsVisibilityAndRating(t *testing.T) {
	db := newCanteenTestDB(t)
	createCanteenTestUser(t, db, 1, "管理员")
	createCanteenTestUser(t, db, 2, "提交者")
	canteen := models.Canteen{
		Name:      "待审食堂",
		Image:     "/uploads/canteen.png",
		CreatedBy: 2,
		Verified:  false,
	}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatalf("create canteen: %v", err)
	}
	handler := NewCanteenHandler(db)

	pending := performCanteenRequest(t, handler.AdminListPending, http.MethodGet, "/api/canteens/pending", nil, 1, "")
	if pending.Code != http.StatusOK || !strings.Contains(pending.Body.String(), "待审食堂") {
		t.Fatalf("pending list status=%d body=%s", pending.Code, pending.Body.String())
	}

	ratingBeforeApproval := performCanteenRequest(
		t,
		handler.Rate,
		http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/rate", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
		2,
		`{"star":5,"comment":"很好"}`,
	)
	if ratingBeforeApproval.Code != http.StatusNotFound {
		t.Fatalf("unverified canteen should not accept ratings: %d %s", ratingBeforeApproval.Code, ratingBeforeApproval.Body.String())
	}

	approved := performCanteenRequest(
		t,
		handler.ApproveCanteen,
		http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/approve", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
		1,
		"",
	)
	if approved.Code != http.StatusOK {
		t.Fatalf("approve status=%d body=%s", approved.Code, approved.Body.String())
	}

	var refreshed models.Canteen
	if err := db.First(&refreshed, canteen.ID).Error; err != nil || !refreshed.Verified {
		t.Fatalf("canteen should be verified after approval: canteen=%+v err=%v", refreshed, err)
	}

	ratingWithoutEdu := performCanteenRequest(
		t,
		handler.Rate,
		http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/rate", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
		2,
		`{"star":5,"comment":"很好"}`,
	)
	if ratingWithoutEdu.Code != http.StatusForbidden ||
		!strings.Contains(ratingWithoutEdu.Body.String(), "edu_binding_required") {
		t.Fatalf("unbound user must not rate: %d %s", ratingWithoutEdu.Code, ratingWithoutEdu.Body.String())
	}

	verifiedAt := time.Now()
	if err := db.Model(&models.User{}).Where("id = ?", 2).Updates(map[string]interface{}{
		"student_verified_at": verifiedAt,
		"edu_authorized":      true,
		"edu_bound":           true,
	}).Error; err != nil {
		t.Fatalf("bind edu account: %v", err)
	}
	ratingAfterApproval := performCanteenRequest(
		t,
		handler.Rate,
		http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/rate", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
		2,
		`{"star":5,"comment":"很好"}`,
	)
	if ratingAfterApproval.Code != http.StatusOK {
		t.Fatalf("verified canteen should accept ratings: %d %s", ratingAfterApproval.Code, ratingAfterApproval.Body.String())
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

func TestCanteenRateWithTagsAndDishRecommendations(t *testing.T) {
	db := newCanteenTestDB(t)
	createCanteenTestUser(t, db, 1, "Alice")
	now := time.Now()
	if err := db.Model(&models.User{}).Where("id = ?", 1).Updates(map[string]interface{}{
		"student_verified_at": now,
		"edu_bound":           true,
	}).Error; err != nil {
		t.Fatalf("bind edu: %v", err)
	}

	canteen := models.Canteen{Name: "第一食堂", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatalf("create canteen: %v", err)
	}

	dish1 := models.CanteenDish{CanteenID: canteen.ID, Name: "牛肉面", NormalizedName: "牛肉面", Status: models.DishStatusActive, CreatedBy: 1}
	dish2 := models.CanteenDish{CanteenID: canteen.ID, Name: "炸酱面", NormalizedName: "炸酱面", Status: models.DishStatusActive, CreatedBy: 1}
	if err := db.Create(&dish1).Error; err != nil {
		t.Fatalf("create dish1: %v", err)
	}
	if err := db.Create(&dish2).Error; err != nil {
		t.Fatalf("create dish2: %v", err)
	}

	handler := NewCanteenHandler(db)

	// 1. 成功提交评价（带标签、推荐菜、图片）
	resp := performCanteenRequest(
		t,
		handler.Rate,
		http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/rate", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
		1,
		fmt.Sprintf(`{
			"star": 5,
			"comment": "非常好吃",
			"images": "[\"/uploads/img1.jpg\",\"/uploads/img2.jpg\"]",
			"tags": ["taste_good", "portion_enough", "taste_good"],
			"recommended_dish_ids": [%d, %d]
		}`, dish1.ID, dish2.ID),
	)
	if resp.Code != http.StatusOK {
		t.Fatalf("rate status=%d body=%s", resp.Code, resp.Body.String())
	}

	// 2. 通过 GetDetail 检验返回数据中的 tags 及 recommended_dishes
	detailResp := performCanteenRequest(
		t,
		handler.GetDetail,
		http.MethodGet,
		fmt.Sprintf("/api/canteens/%d", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
		1,
		"",
	)
	if detailResp.Code != http.StatusOK {
		t.Fatalf("get detail status=%d body=%s", detailResp.Code, detailResp.Body.String())
	}
	var detailData struct {
		Ratings  []models.CanteenRating `json:"ratings"`
		MyRating *models.CanteenRating  `json:"my_rating"`
	}
	if err := json.Unmarshal(detailDataBytes(detailResp.Body.Bytes()), &detailData); err != nil {
		t.Fatalf("unmarshal detail: %v", err)
	}
	if len(detailData.Ratings) != 1 {
		t.Fatalf("expected 1 rating, got %d", len(detailData.Ratings))
	}
	r := detailData.Ratings[0]
	if !strings.Contains(r.Tags, "taste_good") || !strings.Contains(r.Tags, "portion_enough") {
		t.Fatalf("expected tags in rating, got %s", r.Tags)
	}
	if len(r.RecommendedDishes) != 2 || len(r.RecommendedDishIDs) != 2 {
		t.Fatalf("expected 2 recommended dishes, got dishes=%+v ids=%+v", r.RecommendedDishes, r.RecommendedDishIDs)
	}
	if detailData.MyRating == nil || len(detailData.MyRating.RecommendedDishIDs) != 2 {
		t.Fatalf("expected my_rating to have 2 recommendations, got %+v", detailData.MyRating)
	}

	// 3. 修改评价：更改推荐菜为只有 dish1，并更新标签
	updateResp := performCanteenRequest(
		t,
		handler.Rate,
		http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/rate", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
		1,
		fmt.Sprintf(`{
			"star": 4,
			"comment": "改版后稍微淡了一点",
			"images": "[]",
			"tags": ["price_fair"],
			"recommended_dish_ids": [%d]
		}`, dish1.ID),
	)
	if updateResp.Code != http.StatusOK {
		t.Fatalf("update rate status=%d body=%s", updateResp.Code, updateResp.Body.String())
	}

	// 验证关系表已清空旧推荐，仅保留 1 条
	var recCount int64
	db.Model(&models.CanteenRatingDishRecommendation{}).Where("rating_id = ?", r.ID).Count(&recCount)
	if recCount != 1 {
		t.Fatalf("expected 1 recommendation after update, got %d", recCount)
	}
}

func TestCanteenRateValidationRules(t *testing.T) {
	db := newCanteenTestDB(t)
	createCanteenTestUser(t, db, 1, "Alice")
	now := time.Now()
	if err := db.Model(&models.User{}).Where("id = ?", 1).Updates(map[string]interface{}{
		"student_verified_at": now,
		"edu_bound":           true,
	}).Error; err != nil {
		t.Fatalf("bind edu: %v", err)
	}

	c1 := models.Canteen{Name: "食堂1", Image: "/uploads/c1.png", CreatedBy: 1, Verified: true}
	c2 := models.Canteen{Name: "食堂2", Image: "/uploads/c2.png", CreatedBy: 1, Verified: true}
	db.Create(&c1)
	db.Create(&c2)

	d1 := models.CanteenDish{CanteenID: c1.ID, Name: "菜品1", NormalizedName: "菜品1", Status: models.DishStatusActive, CreatedBy: 1}
	d2Cross := models.CanteenDish{CanteenID: c2.ID, Name: "菜品2", NormalizedName: "菜品2", Status: models.DishStatusActive, CreatedBy: 1}
	d3Hidden := models.CanteenDish{CanteenID: c1.ID, Name: "菜品3", NormalizedName: "菜品3", Status: models.DishStatusHidden, CreatedBy: 1}
	db.Create(&d1)
	db.Create(&d2Cross)
	db.Create(&d3Hidden)

	handler := NewCanteenHandler(db)

	tests := []struct {
		name       string
		body       string
		expectCode int
		errSub     string
	}{
		{
			name:       "0星打分拒绝",
			body:       `{"star":0,"comment":"差评"}`,
			expectCode: http.StatusBadRequest,
		},
		{
			name:       "6星打分拒绝",
			body:       `{"star":6,"comment":"超赞"}`,
			expectCode: http.StatusBadRequest,
		},
		{
			name:       "非法标签拒绝",
			body:       `{"star":5,"tags":["illegal_tag"]}`,
			expectCode: http.StatusBadRequest,
			errSub:     "评价标签不合法",
		},
		{
			name:       "标签超过6个拒绝",
			body:       `{"star":5,"tags":["taste_good","portion_enough","price_fair","serving_fast","queue_long","clean","service_warm"]}`,
			expectCode: http.StatusBadRequest,
			errSub:     "最多选择6个体验标签",
		},
		{
			name:       "图片超过3张拒绝",
			body:       `{"star":5,"images":"[\"1.jpg\",\"2.jpg\",\"3.jpg\",\"4.jpg\"]"}`,
			expectCode: http.StatusBadRequest,
			errSub:     "最多只能上传3张评价图片",
		},
		{
			name:       "推荐菜超过3个拒绝",
			body:       `{"star":5,"recommended_dish_ids":[1,2,3,4]}`,
			expectCode: http.StatusBadRequest,
			errSub:     "最多只能推荐3道菜品",
		},
		{
			name:       "跨食堂推荐菜拒绝",
			body:       fmt.Sprintf(`{"star":5,"recommended_dish_ids":[%d, %d]}`, d1.ID, d2Cross.ID),
			expectCode: http.StatusBadRequest,
			errSub:     "推荐菜品不存在或不属于该食堂",
		},
		{
			name:       "隐藏菜品推荐拒绝",
			body:       fmt.Sprintf(`{"star":5,"recommended_dish_ids":[%d]}`, d3Hidden.ID),
			expectCode: http.StatusBadRequest,
			errSub:     "推荐菜品不存在或不属于该食堂",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resp := performCanteenRequest(
				t,
				handler.Rate,
				http.MethodPost,
				fmt.Sprintf("/api/canteens/%d/rate", c1.ID),
				gin.Params{{Key: "id", Value: fmt.Sprint(c1.ID)}},
				1,
				tt.body,
			)
			if resp.Code != tt.expectCode {
				t.Fatalf("expected code %d, got %d, body: %s", tt.expectCode, resp.Code, resp.Body.String())
			}
			if tt.errSub != "" && !strings.Contains(resp.Body.String(), tt.errSub) {
				t.Fatalf("expected body to contain %q, got %s", tt.errSub, resp.Body.String())
			}
		})
	}
}

func detailDataBytes(b []byte) []byte {
	return b
}

