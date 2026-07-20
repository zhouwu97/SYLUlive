package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newPostPollCompatDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "post-poll-compat.db")), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(
		&models.User{}, &models.File{}, &models.Post{}, &models.PostImage{}, &models.Like{}, &models.Reply{},
		&models.WaterSection{}, &models.WaterSectionPin{}, &models.WaterSectionFeaturedPost{},
		&models.WaterTeamRecruitment{}, &models.WaterTeamApplication{},
		&models.Poll{}, &models.PollOption{}, &models.PollBallot{}, &models.PollBallotChoice{},
	); err != nil {
		t.Fatal(err)
	}
	return db
}

func seedNormalAndPollPosts(t *testing.T, db *gorm.DB) (models.Post, models.Post) {
	t.Helper()
	user := models.User{StudentID: "compat-user", PasswordHash: "x", Nickname: "兼容测试"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	normal := models.Post{Title: "普通校园内容", Content: "普通说明", BoardID: models.BoardShuitie, AuthorID: user.ID, ContentKind: models.PostContentKindNormal, Status: models.PostStatusNormal, CreatedAt: now.Add(-time.Minute), LastActivityAt: now.Add(-time.Minute)}
	pollPost := models.Post{Title: "校园投票关键词", Content: "投票说明", BoardID: models.BoardShuitie, AuthorID: user.ID, PostType: "poll", ContentKind: models.PostContentKindPoll, Status: models.PostStatusNormal, CreatedAt: now, LastActivityAt: now}
	if err := db.Create(&normal).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&pollPost).Error; err != nil {
		t.Fatal(err)
	}
	poll := models.Poll{PostID: pollPost.ID, Category: models.PollCategoryOther, SelectionMode: models.PollSelectionSingle, MaxChoices: 1, ResultsVisibility: models.PollResultsAlways, AllowChange: true, IsAnonymous: true, Status: models.PollStatusActive, EndsAt: now.Add(24 * time.Hour)}
	if err := db.Create(&poll).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&[]models.PollOption{{PollID: poll.ID, Text: "赞成", SortOrder: 0}, {PollID: poll.ID, Text: "反对", SortOrder: 1}}).Error; err != nil {
		t.Fatal(err)
	}
	return normal, pollPost
}

func performPostListRequest(t *testing.T, handler gin.HandlerFunc, path string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, path, nil)
	handler(context)
	return recorder
}

func TestHomeFeedV2ExcludesPollAndV3HydratesPoll(t *testing.T) {
	db := newPostPollCompatDB(t)
	_, pollPost := seedNormalAndPollPosts(t, db)
	handler := NewPostHandler(db, "", "")

	v2 := performPostListRequest(t, handler.GetList, "/api/posts?board=1&sort=time&feed_version=2")
	if v2.Code != http.StatusOK {
		t.Fatalf("v2 status=%d body=%s", v2.Code, v2.Body.String())
	}
	var v2Body struct {
		Posts       []models.Post `json:"posts"`
		PinnedPosts []models.Post `json:"pinned_posts"`
	}
	if err := json.Unmarshal(v2.Body.Bytes(), &v2Body); err != nil {
		t.Fatal(err)
	}
	for _, post := range append(v2Body.Posts, v2Body.PinnedPosts...) {
		if post.ID == pollPost.ID {
			t.Fatalf("feed v2 泄露投票: %s", v2.Body.String())
		}
	}

	v3 := performPostListRequest(t, handler.GetList, "/api/posts?board=1&sort=time&feed_version=3&capabilities=poll_v1")
	if v3.Code != http.StatusOK {
		t.Fatalf("v3 status=%d body=%s", v3.Code, v3.Body.String())
	}
	var v3Body struct {
		Posts []models.Post `json:"posts"`
	}
	if err := json.Unmarshal(v3.Body.Bytes(), &v3Body); err != nil {
		t.Fatal(err)
	}
	var found *models.Post
	for i := range v3Body.Posts {
		if v3Body.Posts[i].ID == pollPost.ID {
			found = &v3Body.Posts[i]
		}
	}
	if found == nil || found.PollMeta == nil || len(found.PollMeta.Options) != 2 {
		t.Fatalf("feed v3 未返回完整 poll_meta: %s", v3.Body.String())
	}
}

func TestPinnedV2ExcludesPoll(t *testing.T) {
	db := newPostPollCompatDB(t)
	normal, pollPost := seedNormalAndPollPosts(t, db)
	now := time.Now()
	until := now.Add(time.Hour)
	if err := db.Model(&models.Post{}).Where("id IN ?", []uint{normal.ID, pollPost.ID}).Updates(map[string]interface{}{"is_pinned": true, "pinned_at": now, "pinned_until": until}).Error; err != nil {
		t.Fatal(err)
	}
	handler := NewPostHandler(db, "", "")
	v2 := performPostListRequest(t, handler.GetList, "/api/posts?board=1&sort=time&feed_version=2")
	if v2.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", v2.Code, v2.Body.String())
	}
	var body struct {
		Pinned []models.Post `json:"pinned_posts"`
	}
	if err := json.Unmarshal(v2.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Pinned) != 1 || body.Pinned[0].ID != normal.ID {
		t.Fatalf("v2 置顶兼容错误: %s", v2.Body.String())
	}
}

func TestSearchRequiresPollCapability(t *testing.T) {
	db := newPostPollCompatDB(t)
	_, pollPost := seedNormalAndPollPosts(t, db)
	handler := NewSearchHandler(db, NewPostHandler(db, "", ""))

	legacy := performPostListRequest(t, handler.Search, "/api/search?type=posts&q=校园投票关键词")
	if legacy.Code != http.StatusOK {
		t.Fatalf("legacy status=%d body=%s", legacy.Code, legacy.Body.String())
	}
	var legacyBody struct {
		Items []models.Post `json:"items"`
	}
	if err := json.Unmarshal(legacy.Body.Bytes(), &legacyBody); err != nil {
		t.Fatal(err)
	}
	if len(legacyBody.Items) != 0 {
		t.Fatalf("旧搜索返回了投票: %s", legacy.Body.String())
	}

	modern := performPostListRequest(t, handler.Search, "/api/search?type=posts&q=校园投票关键词&capabilities=poll_v1")
	if modern.Code != http.StatusOK {
		t.Fatalf("modern status=%d body=%s", modern.Code, modern.Body.String())
	}
	var modernBody struct {
		Items []models.Post `json:"items"`
	}
	if err := json.Unmarshal(modern.Body.Bytes(), &modernBody); err != nil {
		t.Fatal(err)
	}
	if len(modernBody.Items) != 1 || modernBody.Items[0].ID != pollPost.ID || modernBody.Items[0].PollMeta == nil {
		t.Fatalf("新搜索未返回投票摘要: %s", modern.Body.String())
	}
}
