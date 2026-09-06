package handlers

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"testing"

	"shenliyuan/internal/models"
)

func TestMarketPostRequiresImage(t *testing.T) {
	tests := []struct {
		name     string
		boardID  models.BoardID
		postType string
		want     bool
	}{
		{name: "普通集市帖子", boardID: models.BoardMarket, postType: "sell", want: true},
		{name: "历史集市帖子类型", boardID: models.BoardMarket, postType: "marketplace_sell", want: true},
		{name: "曝光帖子", boardID: models.BoardMarket, postType: "exposure", want: false},
		{name: "非集市帖子", boardID: models.BoardShuitie, postType: "sell", want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := marketPostRequiresImage(tt.boardID, tt.postType); got != tt.want {
				t.Fatalf("marketPostRequiresImage()=%v, want %v", got, tt.want)
			}
		})
	}
}

func TestCreateMarketPostRequiresImage(t *testing.T) {
	db := newMarketTagsTestDB(t)
	user := createMarketTagsTestUser(t, db, "20260901")

	recorder := performMarketContactRequest(
		t,
		NewPostHandler(db, "", "").Create,
		user.ID,
		0,
		marketImageRequiredForm("sell"),
	)
	assertMarketImageRequired(t, recorder)

	var postCount int64
	if err := db.Model(&models.Post{}).Count(&postCount).Error; err != nil {
		t.Fatalf("count posts: %v", err)
	}
	if postCount != 0 {
		t.Fatalf("post count=%d, want 0", postCount)
	}
}

func TestCreateMarketPostAllowsValidImageAndExposureWithoutImage(t *testing.T) {
	t.Run("有效图片", func(t *testing.T) {
		db := newMarketTagsTestDB(t)
		user := createMarketTagsTestUser(t, db, "20260902")
		image := createMarketTagsTestImage(t, db, user.ID)
		form := marketImageRequiredForm("sell")
		form.Set("file_ids", strconv.FormatUint(uint64(image.ID), 10))

		recorder := performMarketContactRequest(
			t,
			NewPostHandler(db, "", "").Create,
			user.ID,
			0,
			form,
		)
		if recorder.Code != http.StatusCreated {
			t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
		}

		var post models.Post
		if err := json.Unmarshal(recorder.Body.Bytes(), &post); err != nil {
			t.Fatalf("decode response: %v", err)
		}
		var imageCount int64
		if err := db.Model(&models.PostImage{}).Where("post_id = ?", post.ID).Count(&imageCount).Error; err != nil {
			t.Fatalf("count post images: %v", err)
		}
		if imageCount != 1 {
			t.Fatalf("image count=%d, want 1", imageCount)
		}
	})

	t.Run("曝光帖子", func(t *testing.T) {
		db := newMarketTagsTestDB(t)
		user := createMarketTagsTestUser(t, db, "20260903")

		recorder := performMarketContactRequest(
			t,
			NewPostHandler(db, "", "").Create,
			user.ID,
			0,
			marketImageRequiredForm("exposure"),
		)
		if recorder.Code != http.StatusCreated {
			t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
		}
	})
}

func TestUpdateMarketPostRejectsRemovingLastImage(t *testing.T) {
	db := newMarketTagsTestDB(t)
	user := createMarketTagsTestUser(t, db, "20260904")
	post := createMarketTagsTestPost(t, db, user.ID, "")

	var originalImage models.PostImage
	if err := db.Where("post_id = ?", post.ID).First(&originalImage).Error; err != nil {
		t.Fatalf("load original image: %v", err)
	}
	form := marketImageRequiredForm("sell")
	form.Del("board_id")
	form.Set("file_ids", "")

	recorder := performMarketContactRequest(
		t,
		NewPostHandler(db, "", "").Update,
		user.ID,
		post.ID,
		form,
	)
	assertMarketImageRequired(t, recorder)

	var imageCount int64
	if err := db.Model(&models.PostImage{}).Where("post_id = ?", post.ID).Count(&imageCount).Error; err != nil {
		t.Fatalf("count original images: %v", err)
	}
	if imageCount != 1 {
		t.Fatalf("image count=%d, want 1", imageCount)
	}
	var file models.File
	if err := db.First(&file, originalImage.FileID).Error; err != nil {
		t.Fatalf("load original file: %v", err)
	}
	if file.AccessScope != models.FileAccessPublic {
		t.Fatalf("file scope=%q, want %q", file.AccessScope, models.FileAccessPublic)
	}
}

func TestUpdateLegacyMarketPostRequiresImageUntilSupplemented(t *testing.T) {
	db := newMarketTagsTestDB(t)
	user := createMarketTagsTestUser(t, db, "20260905")
	post := models.Post{
		Title:    "历史商品",
		Content:  "历史无图内容",
		BoardID:  models.BoardMarket,
		AuthorID: user.ID,
		PostType: "marketplace_sell",
		Status:   models.PostStatusNormal,
	}
	if err := db.Create(&post).Error; err != nil {
		t.Fatalf("create legacy post: %v", err)
	}

	form := marketImageRequiredForm("marketplace_sell")
	form.Del("board_id")
	recorder := performMarketContactRequest(
		t,
		NewPostHandler(db, "", "").Update,
		user.ID,
		post.ID,
		form,
	)
	assertMarketImageRequired(t, recorder)

	image := createMarketTagsTestImage(t, db, user.ID)
	form.Set("file_ids", strconv.FormatUint(uint64(image.ID), 10))
	recorder = performMarketContactRequest(
		t,
		NewPostHandler(db, "", "").Update,
		user.ID,
		post.ID,
		form,
	)
	if recorder.Code != http.StatusOK {
		t.Fatalf("supplement image status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestUpdateExposureToMarketPostRequiresImage(t *testing.T) {
	db := newMarketTagsTestDB(t)
	user := createMarketTagsTestUser(t, db, "20260906")
	post := models.Post{
		Title:    "曝光记录",
		Content:  "曝光内容",
		BoardID:  models.BoardMarket,
		AuthorID: user.ID,
		PostType: "exposure",
		Status:   models.PostStatusNormal,
	}
	if err := db.Create(&post).Error; err != nil {
		t.Fatalf("create exposure post: %v", err)
	}

	form := marketImageRequiredForm("sell")
	form.Del("board_id")
	recorder := performMarketContactRequest(
		t,
		NewPostHandler(db, "", "").Update,
		user.ID,
		post.ID,
		form,
	)
	assertMarketImageRequired(t, recorder)
}

func TestUpdateMarketPostToExposureAllowsRemovingImages(t *testing.T) {
	db := newMarketTagsTestDB(t)
	user := createMarketTagsTestUser(t, db, "20260907")
	post := createMarketTagsTestPost(t, db, user.ID, "")

	form := marketImageRequiredForm("exposure")
	form.Del("board_id")
	form.Set("file_ids", "")
	recorder := performMarketContactRequest(
		t,
		NewPostHandler(db, "", "").Update,
		user.ID,
		post.ID,
		form,
	)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}

	var saved models.Post
	if err := db.First(&saved, post.ID).Error; err != nil {
		t.Fatalf("load updated post: %v", err)
	}
	if saved.PostType != "exposure" {
		t.Fatalf("post type=%q, want exposure", saved.PostType)
	}
	var imageCount int64
	if err := db.Model(&models.PostImage{}).Where("post_id = ?", post.ID).Count(&imageCount).Error; err != nil {
		t.Fatalf("count post images: %v", err)
	}
	if imageCount != 0 {
		t.Fatalf("image count=%d, want 0", imageCount)
	}
}

func marketImageRequiredForm(postType string) url.Values {
	return url.Values{
		"board_id":  {"2"},
		"title":     {"测试商品"},
		"content":   {"商品描述"},
		"post_type": {postType},
		"price":     {"99"},
	}
}

func assertMarketImageRequired(t *testing.T, recorder interface {
	Result() *http.Response
}) {
	t.Helper()
	response := recorder.Result()
	defer response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("status=%d, want %d", response.StatusCode, http.StatusBadRequest)
	}
	var body struct {
		Code  string `json:"code"`
		Error string `json:"error"`
	}
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.Code != "market_image_required" {
		t.Fatalf("code=%q, want market_image_required", body.Code)
	}
	if body.Error != "普通集市帖子至少需要上传 1 张图片" {
		t.Fatalf("error=%q", body.Error)
	}
}
