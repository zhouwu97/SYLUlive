package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestCreateMarketPostStoresAllowedTagsFromMultipartForm(t *testing.T) {
	db := newMarketTagsTestDB(t)
	user := createMarketTagsTestUser(t, db, "20260003")
	image := createMarketTagsTestImage(t, db, user.ID)

	body, contentType := buildMultipartFields(t, map[string]string{
		"board_id":     "2",
		"title":        "显示器",
		"content":      "成色很好，无坏点",
		"post_type":    "sell",
		"price":        "99",
		"contact":      "wx_contact",
		"contact_type": "wechat",
		"market_tags":  "自提,乱传,急出",
		"file_ids":     strconv.FormatUint(uint64(image.ID), 10),
	})

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Set("user_id", user.ID)
	context.Request = httptest.NewRequest(http.MethodPost, "/api/posts", body)
	context.Request.Header.Set("Content-Type", contentType)

	NewPostHandler(db, "", "").Create(context)

	if recorder.Code != http.StatusCreated {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}

	var responsePost models.Post
	if err := json.Unmarshal(recorder.Body.Bytes(), &responsePost); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if responsePost.MarketTags != "自提,急出" {
		t.Fatalf("response market tags=%q, want 自提,急出", responsePost.MarketTags)
	}

	var saved models.Post
	if err := db.First(&saved, responsePost.ID).Error; err != nil {
		t.Fatalf("load saved post: %v", err)
	}
	if saved.MarketTags != "自提,急出" {
		t.Fatalf("saved market tags=%q, want 自提,急出", saved.MarketTags)
	}
	if saved.Content != "成色很好，无坏点" {
		t.Fatalf("content should not include tags, got %q", saved.Content)
	}
}

func TestCreateMarketPostStoresAllowedTagsOutsideContent(t *testing.T) {
	db := newMarketTagsTestDB(t)
	user := createMarketTagsTestUser(t, db, "20260001")
	image := createMarketTagsTestImage(t, db, user.ID)

	form := url.Values{}
	form.Set("board_id", "2")
	form.Set("title", "显示器")
	form.Set("content", "成色很好，无坏点")
	form.Set("post_type", "sell")
	form.Set("price", "99")
	form.Set("market_tags", "自提,乱传,急出")
	form.Set("file_ids", strconv.FormatUint(uint64(image.ID), 10))

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Set("user_id", user.ID)
	context.Request = httptest.NewRequest(
		http.MethodPost,
		"/api/posts",
		strings.NewReader(form.Encode()),
	)
	context.Request.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	NewPostHandler(db, "", "").Create(context)

	if recorder.Code != http.StatusCreated {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}

	var body models.Post
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.Content != "成色很好，无坏点" {
		t.Fatalf("content should not include tags, got %q", body.Content)
	}
	if body.MarketTags != "自提,急出" {
		t.Fatalf("unexpected market tags: %q", body.MarketTags)
	}
}

func TestUpdateMarketPostCanReplaceAndClearTags(t *testing.T) {
	db := newMarketTagsTestDB(t)
	user := createMarketTagsTestUser(t, db, "20260002")
	post := createMarketTagsTestPost(t, db, user.ID, "自提")

	handler := NewPostHandler(db, "", "")
	body := updateMarketTags(t, handler, user.ID, post.ID, "可小刀,乱传,急出")
	if body.MarketTags != "可小刀,急出" {
		t.Fatalf("unexpected replaced market tags: %q", body.MarketTags)
	}

	body = updateMarketTags(t, handler, user.ID, post.ID, "")
	if body.MarketTags != "" {
		t.Fatalf("expected market tags to be cleared, got %q", body.MarketTags)
	}
}

func TestUpdateMarketPostStoresTagsFromMultipartForm(t *testing.T) {
	db := newMarketTagsTestDB(t)
	user := createMarketTagsTestUser(t, db, "20260004")
	post := createMarketTagsTestPost(t, db, user.ID, "可小刀")

	body, contentType := buildMultipartFields(t, map[string]string{
		"title":        "显示器",
		"content":      "成色很好，无坏点",
		"post_type":    "sell",
		"price":        "88",
		"contact":      "wx_contact",
		"contact_type": "wechat",
		"market_tags":  "自提,乱传,急出",
	})

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Set("user_id", user.ID)
	context.Set("role", "user")
	context.Params = gin.Params{{Key: "id", Value: strconv.FormatUint(uint64(post.ID), 10)}}
	context.Request = httptest.NewRequest(
		http.MethodPut,
		"/api/posts/"+strconv.FormatUint(uint64(post.ID), 10),
		body,
	)
	context.Request.Header.Set("Content-Type", contentType)

	NewPostHandler(db, "", "").Update(context)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}

	var responsePost models.Post
	if err := json.Unmarshal(recorder.Body.Bytes(), &responsePost); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if responsePost.MarketTags != "自提,急出" {
		t.Fatalf("response market tags=%q, want 自提,急出", responsePost.MarketTags)
	}

	var saved models.Post
	if err := db.First(&saved, post.ID).Error; err != nil {
		t.Fatalf("load saved post: %v", err)
	}
	if saved.MarketTags != "自提,急出" {
		t.Fatalf("saved market tags=%q, want 自提,急出", saved.MarketTags)
	}
}

func newMarketTagsTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	t.Setenv("UPLOAD_DIR", t.TempDir())
	dbName := strings.ReplaceAll(t.Name(), "/", "_")
	db, err := gorm.Open(sqlite.Open("file:"+dbName+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.WaterTeamRecruitment{}, &models.WaterTeamApplication{},
		&models.User{},
		&models.ExpLog{},
		&models.Like{},
		&models.File{},
		&models.FileUploadGrant{},
		&models.ImageVariant{},
		&models.Post{},
		&models.PostImage{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

func createMarketTagsTestUser(t *testing.T, db *gorm.DB, studentID string) models.User {
	t.Helper()
	now := time.Now()
	user := models.User{
		StudentID:         studentID,
		StudentVerifiedAt: &now,
		PasswordHash:      "x",
		Nickname:          "卖家",
		EduAuthorized:     true,
		EduBound:          true,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	return user
}

func createMarketTagsTestImage(t *testing.T, db *gorm.DB, uploaderID uint) models.File {
	t.Helper()
	filename := fmt.Sprintf("market-image-%d-%d.png", uploaderID, time.Now().UnixNano())
	if err := os.WriteFile(filepath.Join(os.Getenv("UPLOAD_DIR"), filename), []byte("test image"), 0o600); err != nil {
		t.Fatalf("write market image: %v", err)
	}
	file := models.File{
		Hash:        "market-" + filename,
		Path:        "/uploads/" + filename,
		Size:        int64(len("test image")),
		MimeType:    "image/png",
		UploaderID:  uploaderID,
		Status:      "active",
		AccessScope: models.FileAccessPublic,
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatalf("create market image: %v", err)
	}
	return file
}

func createMarketTagsTestPost(t *testing.T, db *gorm.DB, userID uint, tags string) models.Post {
	t.Helper()
	post := models.Post{
		Title:      "显示器",
		Content:    "成色很好",
		BoardID:    models.BoardMarket,
		AuthorID:   userID,
		PostType:   "sell",
		Price:      99,
		MarketTags: tags,
		Status:     models.PostStatusNormal,
	}
	if err := db.Create(&post).Error; err != nil {
		t.Fatalf("create post: %v", err)
	}
	image := createMarketTagsTestImage(t, db, userID)
	if err := db.Create(&models.PostImage{PostID: post.ID, FileID: image.ID}).Error; err != nil {
		t.Fatalf("create post image: %v", err)
	}
	return post
}

func updateMarketTags(
	t *testing.T,
	handler *PostHandler,
	userID uint,
	postID uint,
	tags string,
) models.Post {
	t.Helper()

	form := url.Values{}
	form.Set("title", "显示器")
	form.Set("content", "成色很好，无坏点")
	form.Set("post_type", "sell")
	form.Set("price", "88")
	form.Set("contact", "wx_contact")
	form.Set("contact_type", "wechat")
	form.Set("market_tags", tags)

	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Set("user_id", userID)
	context.Set("role", "user")
	context.Params = gin.Params{{Key: "id", Value: strconv.FormatUint(uint64(postID), 10)}}
	context.Request = httptest.NewRequest(
		http.MethodPut,
		"/api/posts/"+strconv.FormatUint(uint64(postID), 10),
		strings.NewReader(form.Encode()),
	)
	context.Request.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	handler.Update(context)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}

	var body models.Post
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	return body
}

func buildMultipartFields(t *testing.T, fields map[string]string) (*bytes.Buffer, string) {
	t.Helper()

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	for key, value := range fields {
		if err := writer.WriteField(key, value); err != nil {
			t.Fatalf("write multipart field %s: %v", key, err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close multipart writer: %v", err)
	}
	return &body, writer.FormDataContentType()
}

func TestNormalizeMarketTagsAcceptsTagsForAllPostTypes(t *testing.T) {
	db := newMarketTagsTestDB(t)
	user := createMarketTagsTestUser(t, db, "20260005")

	cases := []struct {
		postType string
		tags     string
		want     string
	}{
		{"sell", "自提,可小刀,乱传", "自提,可小刀"},
		{"buy", "自提,可上门,长期求,急需,乱传", "自提,可上门,长期求,急需"},
		{"lost", "急寻,有酬谢,可面交,乱传", "急寻,有酬谢,可面交"},
		{"found", "待认领,已交宿管,可面交,乱传", "待认领,已交宿管,可面交"},
		{"proxy", "可跑腿,当日完成,可议价,乱传", "可跑腿,当日完成,可议价"},
	}

	for i, tc := range cases {
		image := createMarketTagsTestImage(t, db, user.ID)
		form := url.Values{}
		form.Set("board_id", "2")
		form.Set("title", "测试")
		form.Set("content", "内容")
		form.Set("post_type", tc.postType)
		form.Set("contact", "wx_contact")
		form.Set("contact_type", "wechat")
		form.Set("market_tags", tc.tags)
		form.Set("file_ids", strconv.FormatUint(uint64(image.ID), 10))

		gin.SetMode(gin.TestMode)
		recorder := httptest.NewRecorder()
		context, _ := gin.CreateTestContext(recorder)
		context.Set("user_id", user.ID)
		context.Request = httptest.NewRequest(
			http.MethodPost,
			"/api/posts",
			strings.NewReader(form.Encode()),
		)
		context.Request.Header.Set("Content-Type", "application/x-www-form-urlencoded")

		NewPostHandler(db, "", "").Create(context)

		if recorder.Code != http.StatusCreated {
			t.Fatalf("case %d (%s): status=%d body=%s", i, tc.postType, recorder.Code, recorder.Body.String())
		}

		var body models.Post
		if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
			t.Fatalf("case %d: decode response: %v", i, err)
		}
		if body.MarketTags != tc.want {
			t.Fatalf("case %d (%s): market tags=%q, want %q", i, tc.postType, body.MarketTags, tc.want)
		}

		var saved models.Post
		if err := db.First(&saved, body.ID).Error; err != nil {
			t.Fatalf("case %d: load saved post: %v", i, err)
		}
		if saved.MarketTags != tc.want {
			t.Fatalf("case %d (%s): saved market tags=%q, want %q", i, tc.postType, saved.MarketTags, tc.want)
		}
	}
}
