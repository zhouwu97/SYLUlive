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
	name := strings.NewReplacer("/", "_", "\\", "_").Replace(t.Name())
	db, err := gorm.Open(sqlite.Open("file:"+name+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.Notification{}, &models.WaterTeamRecruitment{}, &models.WaterTeamApplication{},
		&models.User{},
		&models.File{},
		&models.FileUploadGrant{},
		&models.ImageVariant{},
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

	var resultNotification models.Notification
	if err := db.Where("user_id = ? AND type = ? AND related_id = ?", 2, NotificationTypeCanteenReviewResult, canteen.ID).First(&resultNotification).Error; err != nil {
		t.Fatalf("submitter should receive review result notification: %v", err)
	}
	if !strings.Contains(resultNotification.Content, "审核已通过") {
		t.Fatalf("approve notification content=%s", resultNotification.Content)
	}
}

func TestCanteenSubmissionNotifiesAdmins(t *testing.T) {
	db := newCanteenTestDB(t)
	createCanteenTestUser(t, db, 1, "管理员")
	createCanteenTestUser(t, db, 2, "提交者")
	if err := db.Model(&models.User{}).Where("id = ?", 1).Update("role", models.RoleAdmin).Error; err != nil {
		t.Fatalf("set admin role: %v", err)
	}
	handler := NewCanteenHandler(db)

	submitted := performCanteenRequest(
		t,
		handler.Create,
		http.MethodPost,
		"/api/canteens",
		nil,
		2,
		`{"name":"新食堂","image":"/uploads/test-canteen.jpg"}`,
	)
	if submitted.Code != http.StatusBadRequest {
		t.Fatalf("submit with unregistered image should be rejected: %d %s", submitted.Code, submitted.Body.String())
	}

	if err := db.Create(&models.File{
		Hash:       "test-canteen-hash",
		Path:       "/uploads/test-canteen.jpg",
		Size:       1024,
		MimeType:   "image/jpeg",
		UploaderID: 2,
	}).Error; err != nil {
		t.Fatalf("create file: %v", err)
	}

	submitted = performCanteenRequest(
		t,
		handler.Create,
		http.MethodPost,
		"/api/canteens",
		nil,
		2,
		`{"name":"新食堂","image":"/uploads/test-canteen.jpg"}`,
	)
	if submitted.Code != http.StatusCreated {
		t.Fatalf("submit status=%d body=%s", submitted.Code, submitted.Body.String())
	}

	var adminNotification models.Notification
	if err := db.Where("user_id = ? AND type = ? AND related_id = ?", 1, NotificationTypeCanteenPending, 1).First(&adminNotification).Error; err != nil {
		t.Fatalf("admin should receive pending notification: %v", err)
	}
	if !strings.Contains(adminNotification.Content, "新食堂") {
		t.Fatalf("pending notification content=%s", adminNotification.Content)
	}

	// 重复提交同一记录不应产生重复通知（DedupKey）
	var count int64
	if err := db.Model(&models.Notification{}).
		Where("user_id = ? AND type = ? AND related_id = ?", 1, NotificationTypeCanteenPending, 1).
		Count(&count).Error; err != nil {
		t.Fatalf("count admin notifications: %v", err)
	}
	if count != 1 {
		t.Fatalf("expected exactly 1 admin notification, got %d", count)
	}
}

func TestCanteenRejectNotifiesSubmitter(t *testing.T) {
	db := newCanteenTestDB(t)
	createCanteenTestUser(t, db, 1, "管理员")
	createCanteenTestUser(t, db, 2, "提交者")
	canteen := models.Canteen{Name: "重复食堂", Image: "/uploads/canteen.png", CreatedBy: 2, Verified: false}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatalf("create canteen: %v", err)
	}
	handler := NewCanteenHandler(db)

	rejected := performCanteenRequest(
		t,
		handler.RejectCanteen,
		http.MethodDelete,
		fmt.Sprintf("/api/canteens/%d/pending", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
		1,
		`{"reason":"重复提交"}`,
	)
	if rejected.Code != http.StatusOK {
		t.Fatalf("reject status=%d body=%s", rejected.Code, rejected.Body.String())
	}

	var notification models.Notification
	if err := db.Where("user_id = ? AND type = ? AND related_id = ?", 2, NotificationTypeCanteenReviewResult, canteen.ID).First(&notification).Error; err != nil {
		t.Fatalf("submitter should receive reject notification: %v", err)
	}
	if !strings.Contains(notification.Content, "未能通过审核") || !strings.Contains(notification.Content, "重复提交") {
		t.Fatalf("reject notification content=%s", notification.Content)
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

	// 1. 成功提交评价（包含已有菜品、自由文本菜名、去重与多余空格处理）
	resp := performCanteenRequest(
		t,
		handler.Rate,
		http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/rate", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
		1,
		`{
			"star": 5,
			"comment": "非常好吃",
			"images": "[\"/uploads/img1.jpg\",\"/uploads/img2.jpg\"]",
			"tags": ["taste_good", "portion_enough", "taste_good"],
			"recommended_dishes": ["牛肉面", " 炸酱面 ", "自创特色麻辣香锅", "牛肉面"]
		}`,
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
	if len(r.RecommendedDishNames) != 3 {
		t.Fatalf("expected 3 recommended dish names, got %+v", r.RecommendedDishNames)
	}
	if detailData.MyRating == nil || len(detailData.MyRating.RecommendedDishNames) != 3 {
		t.Fatalf("expected my_rating to have 3 recommendations, got %+v", detailData.MyRating)
	}

	// 验证已有菜品匹配到了 DishID，自由输入的菜名 DishID 为 nil
	var recRecords []models.CanteenRatingDishRecommendation
	db.Where("rating_id = ?", r.ID).Order("id ASC").Find(&recRecords)
	if len(recRecords) != 3 {
		t.Fatalf("expected 3 rec records in db, got %d", len(recRecords))
	}
	if recRecords[0].DishID == nil || *recRecords[0].DishID != dish1.ID {
		t.Fatalf("expected rec[0] to match dish1 ID %d, got %+v", dish1.ID, recRecords[0].DishID)
	}
	if recRecords[1].DishID == nil || *recRecords[1].DishID != dish2.ID {
		t.Fatalf("expected rec[1] to match dish2 ID %d, got %+v", dish2.ID, recRecords[1].DishID)
	}
	if recRecords[2].DishID != nil {
		t.Fatalf("expected rec[2] (free-text) DishID to be nil, got %+v", recRecords[2].DishID)
	}

	// 3. 修改评价：更改推荐菜为只有 牛肉面，并更新标签
	updateResp := performCanteenRequest(
		t,
		handler.Rate,
		http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/rate", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
		1,
		`{
			"star": 4,
			"comment": "改版后稍微淡了一点",
			"images": "[]",
			"tags": ["price_fair"],
			"recommended_dishes": ["牛肉面"]
		}`,
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
	db.Create(&c1)

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
			body:       `{"star":5,"recommended_dishes":["菜品1","菜品2","菜品3","菜品4"]}`,
			expectCode: http.StatusBadRequest,
			errSub:     "最多只能推荐3道菜品",
		},
		{
			name:       "推荐菜名超过30字拒绝",
			body:       `{"star":5,"recommended_dishes":["超长菜名超长菜名超长菜名超长菜名超长菜名超长菜名超长菜名超长菜名超长菜名超长菜名!"]}`,
			expectCode: http.StatusBadRequest,
			errSub:     "推荐菜名不能超过30个字符",
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

func setupCanteenTestRouter(db *gorm.DB) *gin.Engine {
	gin.SetMode(gin.TestMode)
	r := gin.New()

	canteenHandler := NewCanteenHandler(db)
	canteenDishHandler := NewCanteenDishHandler(db)
	canteenDishPhotoHandler := NewCanteenDishPhotoHandler(db)
	canteenDishPhotoAdminHandler := NewCanteenDishPhotoAdminHandler(db)

	canteen := r.Group("/api/canteens")
	{
		canteen.GET("", canteenHandler.GetList)
		canteen.GET("/:id", canteenHandler.GetDetail)
		canteen.GET("/:id/dishes", canteenDishHandler.ListDishes)
		canteen.GET("/:id/dishes/:dishId", canteenDishHandler.GetDish)
	}

	canteenAdmin := canteen.Group("")
	{
		canteenAdmin.GET("/pending", canteenHandler.AdminListPending)
		canteenAdmin.POST("/:id/approve", canteenHandler.ApproveCanteen)
		canteenAdmin.DELETE("/:id/pending", canteenHandler.RejectCanteen)
		canteenAdmin.DELETE("/:id", canteenHandler.DeleteCanteen)
		canteenAdmin.PUT("/:id/image", canteenHandler.UpdateImage)

		canteenAdmin.GET("/dish-photos/pending", canteenDishPhotoAdminHandler.AdminListPendingDishPhotos)
		canteenAdmin.GET("/dish-photos/:photoId", canteenDishPhotoAdminHandler.AdminGetDishPhotoDetail)
		canteenAdmin.POST("/dish-photos/:photoId/approve", canteenDishPhotoAdminHandler.ApproveDishPhoto)
		canteenAdmin.POST("/dish-photos/:photoId/reject", canteenDishPhotoAdminHandler.RejectDishPhoto)
		canteenAdmin.POST("/dish-photos/:photoId/archive", canteenDishPhotoAdminHandler.ArchiveDishPhoto)
		canteenAdmin.PATCH("/dishes/:dishId", canteenDishPhotoAdminHandler.AdminUpdateDish)
	}

	canteenAuth := canteen.Group("")
	{
		canteenAuth.POST("", canteenHandler.Create)
		canteenAuth.POST("/:id/rate", canteenHandler.Rate)
		canteenAuth.PUT("/ratings/:ratingId/vote", canteenHandler.VoteRating)
		canteenAuth.POST("/:id/dish-photos", canteenDishPhotoHandler.SubmitDishPhoto)
	}

	return r
}

func TestCanteenRouterRegistration(t *testing.T) {
	db := newCanteenTestDB(t)
	createCanteenTestUser(t, db, 1, "Alice")
	canteen := models.Canteen{Name: "第一食堂", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	db.Create(&canteen)

	r := setupCanteenTestRouter(db)

	// 1. 已审核食堂 + 无菜品：GET /api/canteens/:id/dishes -> 200 []
	req1 := httptest.NewRequest(http.MethodGet, fmt.Sprintf("/api/canteens/%d/dishes", canteen.ID), nil)
	w1 := httptest.NewRecorder()
	r.ServeHTTP(w1, req1)
	if w1.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d, body: %s", w1.Code, w1.Body.String())
	}
	var emptyList []interface{}
	if err := json.Unmarshal(w1.Body.Bytes(), &emptyList); err != nil || len(emptyList) != 0 {
		t.Fatalf("expected empty list [], got: %s", w1.Body.String())
	}

	// 2. 不存在食堂：GET /api/canteens/9999/dishes -> 404
	req2 := httptest.NewRequest(http.MethodGet, "/api/canteens/9999/dishes", nil)
	w2 := httptest.NewRecorder()
	r.ServeHTTP(w2, req2)
	if w2.Code != http.StatusNotFound {
		t.Fatalf("expected status 404 for non-existent canteen, got %d", w2.Code)
	}

	// 3. 添加一道已审核菜品与实拍
	file := models.File{
		ID:         1001,
		Path:       "/uploads/beef.jpg",
		Hash:       "hash-1001",
		Size:       1024,
		MimeType:   "image/jpeg",
		UploaderID: 1,
	}
	db.Create(&file)

	dish := models.CanteenDish{
		CanteenID:      canteen.ID,
		Name:           "招牌牛肉面",
		NormalizedName: "招牌牛肉面",
		Status:         models.DishStatusActive,
		CreatedBy:      1,
	}
	db.Create(&dish)

	photo := models.CanteenDishPhoto{
		DishID: dish.ID,
		FileID: file.ID,
		UserID: 1,
		Status: models.DishPhotoStatusApproved,
	}
	db.Create(&photo)

	// 4. 已审核食堂 + 有菜品：GET /api/canteens/:id/dishes -> 200 非空数组
	req3 := httptest.NewRequest(http.MethodGet, fmt.Sprintf("/api/canteens/%d/dishes", canteen.ID), nil)
	w3 := httptest.NewRecorder()
	r.ServeHTTP(w3, req3)
	if w3.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d, body: %s", w3.Code, w3.Body.String())
	}
	var dishList []map[string]interface{}
	if err := json.Unmarshal(w3.Body.Bytes(), &dishList); err != nil || len(dishList) != 1 {
		t.Fatalf("expected 1 dish in list, got: %s", w3.Body.String())
	}
	if dishList[0]["name"] != "招牌牛肉面" {
		t.Fatalf("expected dish name '招牌牛肉面', got: %v", dishList[0]["name"])
	}

	// 5. 验证单菜品详情路由：GET /api/canteens/:canteenId/dishes/:dishId -> 200
	req4 := httptest.NewRequest(http.MethodGet, fmt.Sprintf("/api/canteens/%d/dishes/%d", canteen.ID, dish.ID), nil)
	w4 := httptest.NewRecorder()
	r.ServeHTTP(w4, req4)
	if w4.Code != http.StatusOK {
		t.Fatalf("expected status 200 for single dish detail, got %d, body: %s", w4.Code, w4.Body.String())
	}
}

func TestCanteenRateUpdatesTimestampAndOptimisticLock(t *testing.T) {
	db := newCanteenTestDB(t)
	handler := &CanteenHandler{db: db}
	user := createCanteenTestUser(t, db, 10, "Student10")
	now := time.Now()
	user.StudentVerifiedAt = &now
	user.EduBound = true
	db.Save(&user)

	canteen := models.Canteen{Name: "第一食堂", Verified: true, CreatedBy: 1}
	db.Create(&canteen)

	// 1. 第一次评价
	body1 := `{"star": 5, "comment": "很好吃", "tags": ["clean"], "recommended_dishes": ["牛肉面"]}`
	w1 := performCanteenRequest(t, handler.Rate, http.MethodPost, fmt.Sprintf("/api/canteens/%d/rate", canteen.ID), gin.Params{{Key: "id", Value: fmt.Sprintf("%d", canteen.ID)}}, 10, body1)
	if w1.Code != http.StatusOK {
		t.Fatalf("首次评价失败: %d %s", w1.Code, w1.Body.String())
	}
	var resp1 struct {
		Rating models.CanteenRating `json:"rating"`
	}
	if err := json.Unmarshal(w1.Body.Bytes(), &resp1); err != nil {
		t.Fatal(err)
	}
	if resp1.Rating.ID == 0 || resp1.Rating.CreatedAt.IsZero() || resp1.Rating.UpdatedAt.IsZero() {
		t.Fatalf("返回评价时间戳未正确填充: %+v", resp1.Rating)
	}
	firstUpdatedAt := resp1.Rating.UpdatedAt

	// 等待一小段时间确保时间戳有区分
	time.Sleep(10 * time.Millisecond)

	// 2. 第二次修改评价
	body2 := `{"star": 4, "comment": "味道变淡了", "tags": ["good_value"], "recommended_dishes": ["小炒肉"]}`
	w2 := performCanteenRequest(t, handler.Rate, http.MethodPost, fmt.Sprintf("/api/canteens/%d/rate", canteen.ID), gin.Params{{Key: "id", Value: fmt.Sprintf("%d", canteen.ID)}}, 10, body2)
	if w2.Code != http.StatusOK {
		t.Fatalf("二次评价失败: %d %s", w2.Code, w2.Body.String())
	}
	var resp2 struct {
		Rating models.CanteenRating `json:"rating"`
	}
	if err := json.Unmarshal(w2.Body.Bytes(), &resp2); err != nil {
		t.Fatal(err)
	}
	if !resp2.Rating.UpdatedAt.After(firstUpdatedAt) {
		t.Fatalf("二次评价 UpdatedAt 应该更新: first=%v, second=%v", firstUpdatedAt, resp2.Rating.UpdatedAt)
	}

	// 3. 传入陈旧的 base_updated_at 应该触发 409 Conflict
	staleBaseTime := firstUpdatedAt.Add(-2 * time.Hour).Format(time.RFC3339)
	body3 := fmt.Sprintf(`{"star": 3, "comment": "冲突旧草稿", "base_updated_at": "%s"}`, staleBaseTime)
	w3 := performCanteenRequest(t, handler.Rate, http.MethodPost, fmt.Sprintf("/api/canteens/%d/rate", canteen.ID), gin.Params{{Key: "id", Value: fmt.Sprintf("%d", canteen.ID)}}, 10, body3)
	if w3.Code != http.StatusConflict {
		t.Fatalf("陈旧草稿应触发 409 conflict, got %d, body: %s", w3.Code, w3.Body.String())
	}
}
