package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestGetUserMarketPostsIncludesMarketTagsAndImagesForEditEntry(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:user_market_posts?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.WaterTeamRecruitment{}, &models.WaterTeamApplication{},
		&models.User{},
		&models.File{},
		&models.ImageVariant{},
		&models.Post{},
		&models.PostImage{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}

	user := models.User{
		StudentID:    "20260005",
		PasswordHash: "x",
		Nickname:     "卖家",
		EduBound:     true,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	file := models.File{
		Hash:     "hash-1",
		Path:     "/uploads/market.jpg",
		Size:     123,
		MimeType: "image/jpeg",
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatalf("create file: %v", err)
	}
	post := models.Post{
		Title:      "显示器",
		Content:    "成色很好",
		BoardID:    models.BoardMarket,
		AuthorID:   user.ID,
		PostType:   "sell",
		Price:      99,
		Contact:    "站内私信",
		MarketTags: "自提,可小刀",
		Status:     models.PostStatusNormal,
	}
	if err := db.Create(&post).Error; err != nil {
		t.Fatalf("create post: %v", err)
	}
	closed := models.Post{
		Title:    "已解决求购",
		Content:  "求购已完成",
		BoardID:  models.BoardMarket,
		AuthorID: user.ID,
		PostType: "buy",
		Status:   models.PostStatusClosed,
	}
	if err := db.Create(&closed).Error; err != nil {
		t.Fatalf("create closed post: %v", err)
	}
	if err := db.Create(&models.PostImage{
		PostID:    post.ID,
		FileID:    file.ID,
		SortOrder: 0,
	}).Error; err != nil {
		t.Fatalf("create post image: %v", err)
	}

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/api/user/1/market-posts?post_type=all", nil)
	context.Params = gin.Params{{Key: "id", Value: "1"}}

	NewUserHandler(db).GetUserMarketPosts(context)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}

	var body map[string]json.RawMessage
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	var posts []models.Post
	if err := json.Unmarshal(body["items"], &posts); err != nil {
		t.Fatalf("decode items: %v", err)
	}
	if len(posts) != 2 {
		t.Fatalf("posts length=%d, want 2; body=%s", len(posts), recorder.Body.String())
	}
	var foundClosed bool
	for _, item := range posts {
		if item.Status == models.PostStatusClosed && item.PostType == "buy" {
			foundClosed = true
		}
	}
	if !foundClosed {
		t.Fatalf("closed market post missing; body=%s", recorder.Body.String())
	}
	var normal *models.Post
	for index := range posts {
		if posts[index].ID == post.ID {
			normal = &posts[index]
		}
	}
	if normal == nil || normal.MarketTags != "自提,可小刀" {
		t.Fatalf("market tags=%v, want normal post with tags; body=%s", normal, recorder.Body.String())
	}
	if len(normal.Images) != 1 {
		t.Fatalf("images length=%d, want 1; body=%s", len(normal.Images), recorder.Body.String())
	}
	if normal.Images[0].File.Path != "/uploads/market.jpg" {
		t.Fatalf("image file path=%q, want /uploads/market.jpg", normal.Images[0].File.Path)
	}
	if strings.Contains(recorder.Body.String(), user.StudentID) {
		t.Fatalf("公开帖子响应泄露作者学号: %s", recorder.Body.String())
	}
}

func TestUserPostListsRespectOwnerAndAdminVisibility(t *testing.T) {
	for _, market := range []bool{false, true} {
		t.Run(strconv.FormatBool(market), func(t *testing.T) {
			db := newPostFeedTestDB(t)
			require.NoError(t, db.AutoMigrate(&models.Topic{}, &models.PostTopic{}))
			author := seedFeedAuthor(t, db)
			other := seedFeedAuthor(t, db)
			board := models.BoardShuitie
			if market {
				board = models.BoardMarket
			}
			normal := seedFeedPost(t, db, author, board, models.PostStatusNormal, "公开记录")
			hidden := seedFeedPost(t, db, author, board, models.PostStatusModeratedHidden, "本人隐藏记录")
			foreign := seedFeedPost(t, db, other, board, models.PostStatusModeratedHidden, "其他作者隐藏记录")
			if market {
				require.NoError(t, db.Model(&models.Post{}).Where("id IN ?", []uint{normal.ID, hidden.ID, foreign.ID}).Update("post_type", "sell").Error)
			}
			h := NewUserHandler(db)
			for _, viewer := range []struct {
				name          string
				id            uint
				role          string
				canReadHidden bool
			}{
				{"guest", 0, "", false},
				{"owner", author.ID, "user", true},
				{"other", other.ID, "user", false},
				{"admin", other.ID, "admin", true},
				{"super_admin", other.ID, "super_admin", true},
			} {
				t.Run(viewer.name, func(t *testing.T) {
					w := httptest.NewRecorder()
					c, _ := gin.CreateTestContext(w)
					id := strconv.FormatUint(uint64(author.ID), 10)
					c.Request = httptest.NewRequest(http.MethodGet, "/api/user/"+id+"/posts", nil)
					c.Params = gin.Params{{Key: "id", Value: id}}
					// 与 JWT 中间件一致地保存 uint，防止测试用 uint64 掩盖所有者判断错误。
					c.Set("user_id", viewer.id)
					c.Set("role", viewer.role)
					var posts []models.Post
					if market {
						h.GetUserMarketPosts(c)
						var body struct {
							Items []models.Post `json:"items"`
							Total int           `json:"total"`
							Sold  int           `json:"sold"`
						}
						require.Equal(t, http.StatusOK, w.Code, w.Body.String())
						require.NoError(t, json.Unmarshal(w.Body.Bytes(), &body))
						posts = body.Items
						require.Equal(t, len(posts), body.Total)
						require.Zero(t, body.Sold, "隐藏记录和在售记录不能被计入已售数量")
					} else {
						h.GetUserPosts(c)
						require.Equal(t, http.StatusOK, w.Code, w.Body.String())
						require.NoError(t, json.Unmarshal(w.Body.Bytes(), &posts))
					}
					ids := make(map[uint]bool)
					for _, post := range posts {
						ids[post.ID] = true
					}
					require.True(t, ids[normal.ID])
					require.Equal(t, viewer.canReadHidden, ids[hidden.ID])
					require.False(t, ids[foreign.ID], "管理员读取目标主页也不能混入其他作者的记录")
				})
			}
		})
	}
}

func TestUserMarketPostFiltersKeepCountsAndPaginationScoped(t *testing.T) {
	db := newPostFeedTestDB(t)
	require.NoError(t, db.AutoMigrate(&models.Topic{}, &models.PostTopic{}))
	author := seedFeedAuthor(t, db)
	other := seedFeedAuthor(t, db)
	for _, fixture := range []struct {
		author   models.User
		postType string
		status   models.PostStatus
	}{
		{author, "sell", models.PostStatusNormal},
		{author, "sell", models.PostStatusSold},
		{author, "buy", models.PostStatusClosed},
		{author, "buy", models.PostStatusModeratedHidden},
		{other, "sell", models.PostStatusSold},
	} {
		post := seedFeedPost(t, db, fixture.author, models.BoardMarket, fixture.status, "筛选记录")
		require.NoError(t, db.Model(&post).Update("post_type", fixture.postType).Error)
	}
	for _, scenario := range []struct {
		name   string
		query  string
		viewer uint
		total  int
		sold   int
	}{
		{"旧客户端默认出售", "", author.ID, 2, 1},
		{"出售筛选去空白", "&post_type=%20sell%20", author.ID, 2, 1},
		{"本人全部类型", "&post_type=all", author.ID, 4, 1},
		{"空筛选全部类型", "&post_type=", author.ID, 4, 1},
		{"访客全部类型", "&post_type=all", 0, 3, 1},
		{"本人求购含隐藏", "&post_type=buy", author.ID, 2, 0},
		{"访客求购已完成", "&post_type=buy", 0, 1, 0},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			w := httptest.NewRecorder()
			c, _ := gin.CreateTestContext(w)
			id := strconv.FormatUint(uint64(author.ID), 10)
			c.Request = httptest.NewRequest(http.MethodGet, "/api/user/"+id+"/market-posts?limit=1"+scenario.query, nil)
			c.Params = gin.Params{{Key: "id", Value: id}}
			c.Set("user_id", scenario.viewer)
			NewUserHandler(db).GetUserMarketPosts(c)
			var body struct {
				Items []models.Post `json:"items"`
				Total int           `json:"total"`
				Sold  int           `json:"sold"`
				Limit int           `json:"limit"`
			}
			require.Equal(t, http.StatusOK, w.Code, w.Body.String())
			require.NoError(t, json.Unmarshal(w.Body.Bytes(), &body))
			require.Len(t, body.Items, 1)
			require.Equal(t, scenario.total, body.Total)
			require.Equal(t, scenario.sold, body.Sold)
			require.Equal(t, 1, body.Limit)
			require.Equal(t, author.ID, body.Items[0].AuthorID)
		})
	}
}
