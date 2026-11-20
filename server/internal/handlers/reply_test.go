package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newReplyTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.Post{},
		&models.Reply{},
		&models.ReplyImage{},
		&models.File{},
		&models.FileUploadGrant{},
		&models.ImageVariant{},
		&models.ExpLog{},
		&models.Notification{},
		&models.Like{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

func createReplyTestPost(t *testing.T, db *gorm.DB) models.Post {
	t.Helper()
	createMessageTestUser(t, db, 1, "Alice")
	now := time.Now()
	post := models.Post{
		Title:          "测试帖子",
		Content:        "正文",
		BoardID:        models.BoardShuitie,
		AuthorID:       1,
		ContentKind:    models.PostContentKindNormal,
		Status:         models.PostStatusNormal,
		CreatedAt:      now,
		LastActivityAt: now,
	}
	if err := db.Create(&post).Error; err != nil {
		t.Fatalf("create post: %v", err)
	}
	return post
}

func performReplyRequest(
	t *testing.T,
	handler gin.HandlerFunc,
	postID uint,
	form url.Values,
) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(
		http.MethodPost,
		fmt.Sprintf("/api/posts/%d/replies", postID),
		strings.NewReader(form.Encode()),
	)
	context.Request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	context.Params = gin.Params{{Key: "id", Value: fmt.Sprint(postID)}}
	context.Set("user_id", uint(1))
	handler(context)
	return recorder
}

func TestReplyCreateAllowsTextWithSticker(t *testing.T) {
	db := newReplyTestDB(t)
	post := createReplyTestPost(t, db)
	handler := NewReplyHandler(db, "", "")

	const stickerID = "0cc4a3688e7b222b977fef3a078619b6"
	response := performReplyRequest(t, handler.Create, post.ID, url.Values{
		"content":    {"晚安"},
		"sticker_id": {stickerID},
		"asset_key":  {"builtin:test:a"},
		"pack_id":    {"test"},
	})
	if response.Code != http.StatusCreated {
		t.Fatalf("create text with sticker reply status=%d body=%s", response.Code, response.Body.String())
	}

	var reply models.Reply
	if err := json.Unmarshal(response.Body.Bytes(), &reply); err != nil {
		t.Fatalf("decode text with sticker reply: %v", err)
	}
	if reply.Content != "晚安" {
		t.Fatalf("content=%q", reply.Content)
	}
	if reply.StickerID == nil || *reply.StickerID != stickerID {
		t.Fatalf("sticker_id=%v body=%s", reply.StickerID, response.Body.String())
	}

	if reply.AssetKey == nil || *reply.AssetKey != "builtin:test:a" || reply.PackID == nil || *reply.PackID != "test" {
		t.Fatalf("resource identity missing: %+v", reply)
	}
	var saved models.Reply
	if err := db.First(&saved, reply.ID).Error; err != nil || saved.AssetKey == nil || *saved.AssetKey != *reply.AssetKey {
		t.Fatalf("resource identity not persisted: %v", err)
	}
}

func TestReplyCreateRejectsImageWithSticker(t *testing.T) {
	db := newReplyTestDB(t)
	post := createReplyTestPost(t, db)
	handler := NewReplyHandler(db, "", "")

	uploadDir := t.TempDir()
	t.Setenv("UPLOAD_DIR", uploadDir)
	if err := os.WriteFile(filepath.Join(uploadDir, "reply.png"), []byte("image"), 0o600); err != nil {
		t.Fatalf("write image: %v", err)
	}
	file := models.File{
		Hash:       "reply-image",
		Path:       "/uploads/reply.png",
		Size:       5,
		MimeType:   "image/png",
		UploaderID: 1,
		Status:     "active",
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatalf("create image file: %v", err)
	}

	const stickerID = "0cc4a3688e7b222b977fef3a078619b6"
	response := performReplyRequest(t, handler.Create, post.ID, url.Values{
		"sticker_id": {stickerID},
		"file_ids":   {fmt.Sprint(file.ID)},
	})
	if response.Code != http.StatusBadRequest {
		t.Fatalf("image with sticker status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestReplyCreateAllowsImageOnly(t *testing.T) {
	db := newReplyTestDB(t)
	post := createReplyTestPost(t, db)
	handler := NewReplyHandler(db, "", "")

	uploadDir := t.TempDir()
	t.Setenv("UPLOAD_DIR", uploadDir)
	if err := os.WriteFile(filepath.Join(uploadDir, "favorite.png"), []byte("image"), 0o600); err != nil {
		t.Fatalf("write image: %v", err)
	}
	file := models.File{
		Hash:       "favorite-image",
		Path:       "/uploads/favorite.png",
		Size:       5,
		MimeType:   "image/png",
		UploaderID: 1,
		Status:     "temporary",
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatalf("create image file: %v", err)
	}

	response := performReplyRequest(t, handler.Create, post.ID, url.Values{
		"file_ids": {fmt.Sprint(file.ID)},
	})
	if response.Code != http.StatusCreated {
		t.Fatalf("create image-only reply status=%d body=%s", response.Code, response.Body.String())
	}

	var reply models.Reply
	if err := json.Unmarshal(response.Body.Bytes(), &reply); err != nil {
		t.Fatalf("decode image-only reply: %v", err)
	}
	if reply.Content != "" || len(reply.Images) != 1 || reply.Images[0].FileID != file.ID {
		t.Fatalf("unexpected image-only reply: %s", response.Body.String())
	}
}

func TestReplyCreateUsesTextInMixedStickerNotification(t *testing.T) {
	db := newReplyTestDB(t)
	createMessageTestUser(t, db, 1, "Alice")
	createMessageTestUser(t, db, 2, "Bob")
	now := time.Now()
	post := models.Post{
		Title:          "Bob 的帖子",
		Content:        "正文",
		BoardID:        models.BoardShuitie,
		AuthorID:       2,
		ContentKind:    models.PostContentKindNormal,
		Status:         models.PostStatusNormal,
		CreatedAt:      now,
		LastActivityAt: now,
	}
	if err := db.Create(&post).Error; err != nil {
		t.Fatalf("create post: %v", err)
	}

	const stickerID = "0cc4a3688e7b222b977fef3a078619b6"
	createResponse := performReplyRequest(t, NewReplyHandler(db, "", "").Create, post.ID, url.Values{
		"content":    {"晚安"},
		"sticker_id": {stickerID},
	})
	if createResponse.Code != http.StatusCreated {
		t.Fatalf("create reply status=%d body=%s", createResponse.Code, createResponse.Body.String())
	}

	notificationResponse := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(notificationResponse)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/notifications", nil)
	context.Set("user_id", uint(2))
	NewNotificationHandler(db).GetNotifications(context)
	if notificationResponse.Code != http.StatusOK {
		t.Fatalf("get notifications status=%d body=%s", notificationResponse.Code, notificationResponse.Body.String())
	}
	var notifications []models.Notification
	if err := json.Unmarshal(notificationResponse.Body.Bytes(), &notifications); err != nil {
		t.Fatalf("decode notifications: %v", err)
	}
	if len(notifications) != 1 || notifications[0].Content != "晚安" {
		t.Fatalf("notifications=%s", notificationResponse.Body.String())
	}
}

func TestReplyCreateNotifiesMentionedUsers(t *testing.T) {
	db := newReplyTestDB(t)
	post := createReplyTestPost(t, db)
	createMessageTestUser(t, db, 2, "Bob")
	createMessageTestUser(t, db, 3, "Carol")
	handler := NewReplyHandler(db, "", "")

	for _, raw := range []string{"2,abc", "1,2,3,4,5,6,7,8,9,10,11"} {
		response := performReplyRequest(t, handler.Create, post.ID, url.Values{
			"content":          {"你们看"},
			"mention_user_ids": {raw},
		})
		if response.Code != http.StatusBadRequest {
			t.Fatalf("mention_user_ids=%q status=%d body=%s", raw, response.Code, response.Body.String())
		}
	}

	// 自己、重复 ID 与不存在的用户都不产生通知。
	response := performReplyRequest(t, handler.Create, post.ID, url.Values{
		"content":          {"你们看"},
		"mention_user_ids": {"2,1,3,2,99"},
	})
	if response.Code != http.StatusCreated {
		t.Fatalf("create reply status=%d body=%s", response.Code, response.Body.String())
	}
	var notifications []models.Notification
	if err := db.Order("user_id").Find(&notifications).Error; err != nil {
		t.Fatalf("load notifications: %v", err)
	}
	if len(notifications) != 2 ||
		notifications[0].UserID != 2 || notifications[1].UserID != 3 ||
		notifications[0].Content != "@了你：你们看" || notifications[0].Type != "reply" {
		t.Fatalf("notifications=%+v", notifications)
	}

	var created models.Reply
	if err := json.Unmarshal(response.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode reply: %v", err)
	}
	var saved models.Reply
	if err := db.First(&saved, created.ID).Error; err != nil {
		t.Fatalf("load reply: %v", err)
	}
	want := []models.ReplyMention{{UserID: 1, Nickname: "Alice"}, {UserID: 2, Nickname: "Bob"}, {UserID: 3, Nickname: "Carol"}}
	if fmt.Sprint(created.Mentions) != fmt.Sprint(want) || fmt.Sprint(saved.Mentions) != fmt.Sprint(want) {
		t.Fatalf("response mentions=%+v saved=%+v", created.Mentions, saved.Mentions)
	}

	// 列表的根评论与楼中楼预览都要带回 mentions，客户端才能高亮。
	child := performReplyRequest(t, handler.Create, post.ID, url.Values{
		"content":          {"@Carol 来"},
		"parent_reply_id":  {fmt.Sprint(created.ID)},
		"mention_user_ids": {"3"},
	})
	if child.Code != http.StatusCreated {
		t.Fatalf("create child status=%d body=%s", child.Code, child.Body.String())
	}
	list := performReplyListRequest(t, db, post.ID, "", 0).Body.String()
	if strings.Count(list, `"mentions":[{"user_id":`) != 2 {
		t.Fatalf("list body=%s", list)
	}
}

func performReplyReadRequest(
	t *testing.T,
	handler gin.HandlerFunc,
	postID, replyID uint,
	loggedInUserID uint,
) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(
		http.MethodGet,
		fmt.Sprintf("/api/posts/%d/replies/%d/context", postID, replyID),
		nil,
	)
	context.Params = gin.Params{
		{Key: "id", Value: fmt.Sprint(postID)},
		{Key: "replyId", Value: fmt.Sprint(replyID)},
	}
	if loggedInUserID != 0 {
		context.Set("user_id", loggedInUserID)
	}
	handler(context)
	return recorder
}

// TestReplyDeepLinksEnforcePostVisibility 回归 P1-1：帖子被 moderated_hidden/deleted 后，
// 评论的 children/context 深链接口也必须按同一可见性边界拦截匿名访问。
func TestReplyDeepLinksEnforcePostVisibility(t *testing.T) {
	db := newReplyTestDB(t)
	post := createReplyTestPost(t, db)
	handler := NewReplyHandler(db, "", "")

	root := models.Reply{PostID: post.ID, AuthorID: 1, Content: "根评论", Status: models.ReplyStatusNormal}
	if err := db.Create(&root).Error; err != nil {
		t.Fatalf("create root reply: %v", err)
	}
	child := models.Reply{PostID: post.ID, AuthorID: 1, ParentReplyID: &root.ID, Content: "子评论", Status: models.ReplyStatusNormal}
	if err := db.Create(&child).Error; err != nil {
		t.Fatalf("create child reply: %v", err)
	}

	// normal 帖：匿名可读
	if code := performReplyReadRequest(t, handler.GetReplyContext, post.ID, child.ID, 0).Code; code != http.StatusOK {
		t.Fatalf("normal post anonymous context status=%d", code)
	}
	if code := performReplyReadRequest(t, handler.GetChildren, post.ID, root.ID, 0).Code; code != http.StatusOK {
		t.Fatalf("normal post anonymous children status=%d", code)
	}

	// 隐藏帖：匿名应 404
	if err := db.Model(&models.Post{}).Where("id = ?", post.ID).Update("status", models.PostStatusModeratedHidden).Error; err != nil {
		t.Fatalf("hide post: %v", err)
	}
	if code := performReplyReadRequest(t, handler.GetReplyContext, post.ID, child.ID, 0).Code; code != http.StatusNotFound {
		t.Fatalf("hidden post anonymous context status=%d, want 404", code)
	}
	if code := performReplyReadRequest(t, handler.GetChildren, post.ID, root.ID, 0).Code; code != http.StatusNotFound {
		t.Fatalf("hidden post anonymous children status=%d, want 404", code)
	}

	// 隐藏帖：作者可读
	if code := performReplyReadRequest(t, handler.GetReplyContext, post.ID, child.ID, post.AuthorID).Code; code != http.StatusOK {
		t.Fatalf("hidden post owner context status=%d, want 200", code)
	}
	if code := performReplyReadRequest(t, handler.GetChildren, post.ID, root.ID, post.AuthorID).Code; code != http.StatusOK {
		t.Fatalf("hidden post owner children status=%d, want 200", code)
	}

	// deleted 帖：匿名应 404
	if err := db.Model(&models.Post{}).Where("id = ?", post.ID).Update("status", models.PostStatusDeleted).Error; err != nil {
		t.Fatalf("delete post: %v", err)
	}
	if code := performReplyReadRequest(t, handler.GetReplyContext, post.ID, child.ID, 0).Code; code != http.StatusNotFound {
		t.Fatalf("deleted post anonymous context status=%d, want 404", code)
	}
	if code := performReplyReadRequest(t, handler.GetChildren, post.ID, root.ID, 0).Code; code != http.StatusNotFound {
		t.Fatalf("deleted post anonymous children status=%d, want 404", code)
	}
}
