package handlers

import (
	"net/http"
	"strconv"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"shenliyuan/internal/models"
)

func TestCanteenOfflineOnlinePreservesHistoryAndBlocksNewWrites(t *testing.T) {
	h, canteen, user := prepareReviewV2DB(t)
	legacy := models.CanteenRating{CanteenID: canteen.ID, UserID: user.ID, Star: 4, Comment: "历史评价"}
	if err := h.db.Create(&legacy).Error; err != nil {
		t.Fatalf("create legacy rating: %v", err)
	}
	created := performCanteenRequest(t, h.CreateReview, http.MethodPost,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID, reviewBody())
	if created.Code != http.StatusCreated {
		t.Fatalf("create v2 review status=%d body=%s", created.Code, created.Body.String())
	}
	var review models.CanteenReviewEvent
	if err := h.db.Order("id DESC").First(&review).Error; err != nil {
		t.Fatalf("load review: %v", err)
	}

	offline := performCanteenRequest(t, h.OfflineCanteen, http.MethodPost,
		"/api/canteens/88/offline", mapParams("id", "88"), user.ID, `{"reason":"窗口已撤销"}`)
	if offline.Code != http.StatusOK || !strings.Contains(offline.Body.String(), `"operating_status":"offline"`) {
		t.Fatalf("offline status=%d body=%s", offline.Code, offline.Body.String())
	}
	// 重复下架不刷新时间，也不删除任何历史内容。
	var first models.Canteen
	if err := h.db.First(&first, canteen.ID).Error; err != nil {
		t.Fatal(err)
	}
	firstOfflinedAt := first.OfflinedAt
	repeat := performCanteenRequest(t, h.OfflineCanteen, http.MethodPost,
		"/api/canteens/88/offline", mapParams("id", "88"), user.ID, `{}`)
	if repeat.Code != http.StatusOK {
		t.Fatalf("repeat offline status=%d body=%s", repeat.Code, repeat.Body.String())
	}
	var second models.Canteen
	if err := h.db.First(&second, canteen.ID).Error; err != nil {
		t.Fatal(err)
	}
	if firstOfflinedAt == nil || second.OfflinedAt == nil || !firstOfflinedAt.Equal(*second.OfflinedAt) {
		t.Fatalf("repeat offline changed timestamp: first=%v second=%v", firstOfflinedAt, second.OfflinedAt)
	}

	newReview := performCanteenRequest(t, h.CreateReview, http.MethodPost,
		"/api/canteens/88/reviews", mapParams("id", "88"), user.ID, reviewBody())
	if newReview.Code != http.StatusConflict || !strings.Contains(newReview.Body.String(), "canteen_offline") {
		t.Fatalf("offline create review status=%d body=%s", newReview.Code, newReview.Body.String())
	}
	if updateOffline := performCanteenRequest(t, h.UpdateReview, http.MethodPatch,
		"/api/canteens/reviews/"+itoaForTest(review.ID), mapParams("reviewId", itoaForTest(review.ID)), user.ID,
		`{"taste_score":4,"value_score":4,"queue_score":4,"hygiene_score":4,"service_score":4,"comment":"修改历史"}`); updateOffline.Code != http.StatusConflict || !strings.Contains(updateOffline.Body.String(), "canteen_offline") {
		t.Fatalf("offline update review status=%d body=%s", updateOffline.Code, updateOffline.Body.String())
	}

	dish := models.CanteenDish{CanteenID: canteen.ID, Name: "鸡排", NormalizedName: "鸡排", Status: models.DishStatusActive, CreatedBy: user.ID}
	if err := h.db.Create(&dish).Error; err != nil {
		t.Fatal(err)
	}
	dishReview := performCanteenRequest(t, h.CreateDishReview, http.MethodPost,
		"/api/canteens/dishes/"+itoaForTest(dish.ID)+"/reviews", mapParams("dishId", itoaForTest(dish.ID)), user.ID,
		`{"taste_score":4,"value_score":4,"portion_score":4}`)
	if dishReview.Code != http.StatusConflict || !strings.Contains(dishReview.Body.String(), "canteen_offline") {
		t.Fatalf("offline dish review status=%d body=%s", dishReview.Code, dishReview.Body.String())
	}
	photoHandler := NewCanteenDishPhotoHandler(h.db)
	for _, submit := range []gin.HandlerFunc{photoHandler.SubmitDishPhoto, photoHandler.SubmitDishPhotoV2} {
		photo := performCanteenRequest(t, submit, http.MethodPost,
			"/api/canteens/88/dish-submissions", mapParams("id", "88"), user.ID,
			`{"dish_name":"麻辣烫","file_id":1}`)
		if photo.Code != http.StatusGone || !strings.Contains(photo.Body.String(), "dish_submission_retired") {
			t.Fatalf("offline dish submission status=%d body=%s", photo.Code, photo.Body.String())
		}
	}

	detail := performCanteenRequest(t, h.GetDetail, http.MethodGet,
		"/api/canteens/88", mapParams("id", "88"), 0, "")
	if detail.Code != http.StatusOK || !strings.Contains(detail.Body.String(), `"operating_status":"offline"`) || !strings.Contains(detail.Body.String(), `"reviewer_count":1`) {
		t.Fatalf("offline detail status=%d body=%s", detail.Code, detail.Body.String())
	}

	online := performCanteenRequest(t, h.OnlineCanteen, http.MethodPost,
		"/api/canteens/88/online", mapParams("id", "88"), user.ID, `{}`)
	if online.Code != http.StatusOK || !strings.Contains(online.Body.String(), `"operating_status":"active"`) {
		t.Fatalf("online status=%d body=%s", online.Code, online.Body.String())
	}
	var restored models.CanteenReviewEvent
	if err := h.db.First(&restored, review.ID).Error; err != nil {
		t.Fatalf("history was deleted after online: %v", err)
	}
}

func TestOfflineCanteenIsExcludedFromRankingsButListAndDetailKeepIt(t *testing.T) {
	db := newCanteenTestDB(t)
	if err := models.EnsureCanteenReviewSchema(db); err != nil {
		t.Fatal(err)
	}
	user := createCanteenTestUser(t, db, 1, "管理员")
	active := models.Canteen{Name: "营业店", Image: "/uploads/a.png", CreatedBy: user.ID, Verified: true}
	offline := models.Canteen{Name: "下架店", Image: "/uploads/b.png", CreatedBy: user.ID, Verified: true, OperatingStatus: models.CanteenOperatingOffline}
	if err := db.Create(&active).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&offline).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenRating{CanteenID: active.ID, UserID: user.ID, Star: 3}).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenRating{CanteenID: offline.ID, UserID: user.ID, Star: 5}).Error; err != nil {
		t.Fatal(err)
	}
	h := NewCanteenHandler(db)
	canteenDiscoveryCache.Invalidate()
	rank := performCanteenRequest(t, h.GetRankings, http.MethodGet, "/api/canteens/rankings", nil, 0, "")
	if rank.Code != http.StatusOK || strings.Contains(rank.Body.String(), "下架店") {
		t.Fatalf("offline store entered rankings: %d %s", rank.Code, rank.Body.String())
	}
	list := performCanteenRequest(t, h.GetList, http.MethodGet, "/api/canteens", nil, 0, "")
	if list.Code != http.StatusOK || !strings.Contains(list.Body.String(), "下架店") {
		t.Fatalf("offline store disappeared from list/search: %d %s", list.Code, list.Body.String())
	}
}

func TestDeleteCanteenRemovesDependencyTreeWithoutDeletingFile(t *testing.T) {
	db := newCanteenTestDB(t)
	if err := models.EnsureCanteenReviewSchema(db); err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.Report{}); err != nil {
		t.Fatal(err)
	}
	admin := createCanteenTestUser(t, db, 1, "管理员")
	canteen := models.Canteen{Name: "待删除店", Image: "/uploads/c.png", CreatedBy: admin.ID, Verified: true, OperatingStatus: models.CanteenOperatingOffline}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatal(err)
	}
	dish := models.CanteenDish{CanteenID: canteen.ID, Name: "鸡排", NormalizedName: "鸡排", Status: models.DishStatusHidden, CreatedBy: admin.ID}
	if err := db.Create(&dish).Error; err != nil {
		t.Fatal(err)
	}
	file := models.File{Hash: "delete-tree-hash", Path: "/uploads/delete-tree.png", Size: 1, MimeType: "image/png", UploaderID: admin.ID, Status: "active", AccessScope: models.FileAccessPublic}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	photo := models.CanteenDishPhoto{DishID: dish.ID, FileID: file.ID, UserID: admin.ID, Status: models.DishPhotoStatusApproved}
	if err := db.Create(&photo).Error; err != nil {
		t.Fatal(err)
	}
	rating := models.CanteenRating{CanteenID: canteen.ID, UserID: admin.ID, Star: 4}
	if err := db.Create(&rating).Error; err != nil {
		t.Fatal(err)
	}
	rec := models.CanteenRatingDishRecommendation{RatingID: rating.ID, DishName: "鸡排", NormalizedName: "鸡排", DishID: &dish.ID}
	vote := models.CanteenRatingVote{RatingID: rating.ID, UserID: admin.ID, VoteType: "helpful"}
	if err := db.Create(&rec).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&vote).Error; err != nil {
		t.Fatal(err)
	}
	event := models.CanteenReviewEvent{CanteenID: canteen.ID, UserID: admin.ID, OverallScore: 4, Status: models.ReviewEventStatusActive, ScoreVersion: 2}
	if err := db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenReviewEventDish{ReviewEventID: event.ID, DishID: dish.ID, Relation: models.DishReviewRelationAte}).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenReviewEventVote{ReviewEventID: event.ID, UserID: admin.ID, VoteType: "up"}).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenDishReviewEvent{DishID: dish.ID, UserID: admin.ID, OverallScore: 4, Status: models.ReviewEventStatusActive, CanteenReviewEventID: &event.ID}).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenDishRatingSummary{DishID: dish.ID, UserID: admin.ID, EffectiveScore: 4}).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenDishAlias{CanteenID: canteen.ID, DishID: dish.ID, Alias: "鸡排饭", NormalizedAlias: "鸡排饭", CreatedBy: admin.ID}).Error; err != nil {
		t.Fatal(err)
	}
	report := models.Report{ReporterID: admin.ID, TargetType: "canteen_review", TargetID: event.ID, Reason: "test", Status: models.ReportStatusHandled}
	if err := db.Create(&report).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenSanction{ReportID: report.ID, TargetType: "canteen_review", TargetID: event.ID, UserID: admin.ID, Points: 5, ReasonCode: "fabricated", AdminID: admin.ID}).Error; err != nil {
		t.Fatal(err)
	}

	h := NewCanteenHandler(db)
	deleted := performCanteenRequest(t, h.DeleteCanteen, http.MethodDelete, "/api/canteens/"+itoaForTest(canteen.ID), mapParams("id", itoaForTest(canteen.ID)), admin.ID, "")
	if deleted.Code != http.StatusOK {
		t.Fatalf("delete status=%d body=%s", deleted.Code, deleted.Body.String())
	}
	for _, check := range []struct {
		name  string
		model interface{}
	}{
		{"canteen", &models.Canteen{}}, {"rating", &models.CanteenRating{}}, {"vote", &models.CanteenRatingVote{}},
		{"recommendation", &models.CanteenRatingDishRecommendation{}}, {"event", &models.CanteenReviewEvent{}}, {"review event vote", &models.CanteenReviewEventVote{}}, {"relation", &models.CanteenReviewEventDish{}},
		{"dish event", &models.CanteenDishReviewEvent{}}, {"summary", &models.CanteenDishRatingSummary{}}, {"alias", &models.CanteenDishAlias{}},
		{"photo", &models.CanteenDishPhoto{}}, {"dish", &models.CanteenDish{}}, {"sanction", &models.CanteenSanction{}},
	} {
		var count int64
		if err := db.Model(check.model).Count(&count).Error; err != nil {
			t.Fatalf("count %s: %v", check.name, err)
		}
		if count != 0 {
			t.Fatalf("%s rows remain: %d", check.name, count)
		}
	}
	var retained models.File
	if err := db.First(&retained, file.ID).Error; err != nil {
		t.Fatalf("file was physically deleted: %v", err)
	}
	if retained.AccessScope != models.FileAccessPrivate {
		t.Fatalf("file access scope=%s want private after last public reference removed", retained.AccessScope)
	}
}

func TestMergeDishMovesAllRelationsAndLeavesNoHiddenSourceReferences(t *testing.T) {
	db := newCanteenTestDB(t)
	if err := models.EnsureCanteenReviewSchema(db); err != nil {
		t.Fatal(err)
	}
	admin := createCanteenTestUser(t, db, 1, "管理员")
	canteen := models.Canteen{Name: "合并测试店", Image: "/uploads/merge.png", CreatedBy: admin.ID, Verified: true}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatal(err)
	}
	target := models.CanteenDish{CanteenID: canteen.ID, Name: "鸡排饭", NormalizedName: "鸡排饭", Status: models.DishStatusActive, CreatedBy: admin.ID}
	source := models.CanteenDish{CanteenID: canteen.ID, Name: "鸡排", NormalizedName: "鸡排", Status: models.DishStatusPending, CreatedBy: admin.ID}
	if err := db.Create(&target).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&source).Error; err != nil {
		t.Fatal(err)
	}
	file := models.File{Hash: "merge-photo-hash", Path: "/uploads/merge-photo.png", Size: 1, MimeType: "image/png", UploaderID: admin.ID, Status: "active", AccessScope: models.FileAccessPublic}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenDishPhoto{DishID: source.ID, FileID: file.ID, UserID: admin.ID, Status: models.DishPhotoStatusApproved}).Error; err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		f := models.File{Hash: "merge-target-hash-" + strconv.Itoa(i), Path: "/uploads/merge-target-" + strconv.Itoa(i) + ".png", Size: 1, MimeType: "image/png", UploaderID: admin.ID, Status: "active", AccessScope: models.FileAccessPublic}
		if err := db.Create(&f).Error; err != nil {
			t.Fatal(err)
		}
		if err := db.Create(&models.CanteenDishPhoto{DishID: target.ID, FileID: f.ID, UserID: admin.ID, Status: models.DishPhotoStatusApproved}).Error; err != nil {
			t.Fatal(err)
		}
	}
	rating := models.CanteenRating{CanteenID: canteen.ID, UserID: admin.ID, Star: 4}
	if err := db.Create(&rating).Error; err != nil {
		t.Fatal(err)
	}
	dishID := source.ID
	if err := db.Create(&models.CanteenRatingDishRecommendation{RatingID: rating.ID, DishName: "鸡排", NormalizedName: "鸡排", DishID: &dishID}).Error; err != nil {
		t.Fatal(err)
	}
	event := models.CanteenReviewEvent{CanteenID: canteen.ID, UserID: admin.ID, OverallScore: 4, Status: models.ReviewEventStatusActive, ScoreVersion: 2}
	if err := db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenReviewEventDish{ReviewEventID: event.ID, DishID: source.ID, Relation: models.DishReviewRelationAte}).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenReviewEventDish{ReviewEventID: event.ID, DishID: target.ID, Relation: models.DishReviewRelationAte}).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenDishReviewEvent{DishID: source.ID, UserID: admin.ID, OverallScore: 4, TasteScore: 4, ValueScore: 4, PortionScore: 4, Status: models.ReviewEventStatusActive}).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenDishRatingSummary{DishID: source.ID, UserID: admin.ID, EffectiveScore: 4}).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenDishAlias{CanteenID: canteen.ID, DishID: source.ID, Alias: "鸡排", NormalizedAlias: "鸡排", CreatedBy: admin.ID}).Error; err != nil {
		t.Fatal(err)
	}

	h := NewCanteenDishPhotoAdminHandler(db)
	resp := performCanteenRequest(t, h.AdminMergeDish, http.MethodPost,
		"/api/canteens/dishes/"+itoaForTest(source.ID)+"/merge", mapParams("dishId", itoaForTest(source.ID)), admin.ID,
		`{"target_dish_id":`+itoaForTest(target.ID)+`}`)
	if resp.Code != http.StatusOK {
		t.Fatalf("merge status=%d body=%s", resp.Code, resp.Body.String())
	}
	var merged models.CanteenDish
	if err := db.First(&merged, source.ID).Error; err != nil || merged.Status != models.DishStatusMerged {
		t.Fatalf("source status=%+v err=%v", merged, err)
	}
	if merged.MergedIntoDishID == nil || *merged.MergedIntoDishID != target.ID {
		t.Fatalf("merged target id=%v want %d", merged.MergedIntoDishID, target.ID)
	}
	var sourcePhotoCount, sourceRelationCount, sourceRecommendationCount, sourceAliasCount int64
	db.Model(&models.CanteenDishPhoto{}).Where("dish_id = ?", source.ID).Count(&sourcePhotoCount)
	db.Model(&models.CanteenReviewEventDish{}).Where("dish_id = ?", source.ID).Count(&sourceRelationCount)
	db.Model(&models.CanteenRatingDishRecommendation{}).Where("dish_id = ?", source.ID).Count(&sourceRecommendationCount)
	db.Model(&models.CanteenDishAlias{}).Where("dish_id = ?", source.ID).Count(&sourceAliasCount)
	if sourcePhotoCount != 0 || sourceRelationCount != 0 || sourceRecommendationCount != 0 || sourceAliasCount != 0 {
		t.Fatalf("merged source still referenced: photo=%d relation=%d recommendation=%d alias=%d", sourcePhotoCount, sourceRelationCount, sourceRecommendationCount, sourceAliasCount)
	}
	var relationCount, reviewCount, summaryCount int64
	db.Model(&models.CanteenReviewEventDish{}).Where("review_event_id = ? AND dish_id = ?", event.ID, target.ID).Count(&relationCount)
	db.Model(&models.CanteenDishReviewEvent{}).Where("dish_id = ?", target.ID).Count(&reviewCount)
	db.Model(&models.CanteenDishRatingSummary{}).Where("dish_id = ?", target.ID).Count(&summaryCount)
	if relationCount != 1 || reviewCount != 1 || summaryCount != 1 {
		t.Fatalf("target relations not rebuilt: relation=%d reviews=%d summaries=%d", relationCount, reviewCount, summaryCount)
	}
	contributions := performCanteenRequest(t, NewCanteenHandler(db).GetMyCanteenContributions, http.MethodGet,
		"/api/user/canteen-contributions", nil, admin.ID, "")
	if contributions.Code != http.StatusOK || !strings.Contains(contributions.Body.String(), "merged_into_dish_name") ||
		!strings.Contains(contributions.Body.String(), target.Name) {
		t.Fatalf("merged contribution target missing: status=%d body=%s", contributions.Code, contributions.Body.String())
	}
}

func itoaForTest(value uint) string {
	return strconv.FormatUint(uint64(value), 10)
}
