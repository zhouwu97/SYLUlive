package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// 注意：本单元测试文件使用内存 SQLite (glebarez/sqlite) 进行逻辑回归。
// 生产环境 PostgreSQL 的 partial unique index (`WHERE status='pending'`)
// 以及 pgconn.PgError (Code 23505) 并发路径由代码防范逻辑与 PostgreSQL DDL 合约保证。

func newFeaturedTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db failed: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.Post{},
		&models.WaterSection{},
		&models.WaterSectionModerator{},
		&models.WaterSectionFeaturedPost{},
		&models.WaterModerationLog{},
		&models.FeaturedApplication{},
	); err != nil {
		t.Fatalf("auto migrate failed: %v", err)
	}
	return db
}

// 1. 测试 ReviewerID 为 NULL 的 pending 申请创建与查询
func TestFeaturedApplication_ReviewerID_Nullable(t *testing.T) {
	db := newFeaturedTestDB(t)

	app := models.FeaturedApplication{
		PostID:      1,
		ApplicantID: 10,
		Reason:      "求精",
		Status:      "pending",
		ReviewerID:  nil,
	}
	if err := db.Create(&app).Error; err != nil {
		t.Fatalf("create featured app failed: %v", err)
	}

	var fetched models.FeaturedApplication
	if err := db.First(&fetched, app.ID).Error; err != nil {
		t.Fatalf("find featured app failed: %v", err)
	}
	if fetched.ReviewerID != nil {
		t.Fatalf("expected ReviewerID to be nil, got %v", *fetched.ReviewerID)
	}
}

// 2. 测试精华申请状态接口作用域与 DB 错误处理
func TestFeaturedApplicationStatus_ScopeAndDBError(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newFeaturedTestDB(t)
	handler := &PostHandler{db: db}

	// 创建已申请帖
	app := models.FeaturedApplication{
		PostID:      100,
		ApplicantID: 1, // User A
		Reason:      "User A 申请",
		Status:      "pending",
		Source:      "user",
	}
	db.Create(&app)

	// User B 查询 -> has_pending=true, is_mine=false
	r := gin.New()
	r.GET("/posts/:id/featured-application-status", func(c *gin.Context) {
		c.Set("user_id", uint(2)) // User B
		handler.GetFeaturedApplicationStatus(c)
	})

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("GET", "/posts/100/featured-application-status", nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", w.Code)
	}

	var resp map[string]interface{}
	json.Unmarshal(w.Body.Bytes(), &resp)

	if resp["has_pending"] != true {
		t.Fatalf("expected has_pending true, got %v", resp["has_pending"])
	}
	if resp["is_mine"] != false {
		t.Fatalf("expected is_mine false for User B, got %v", resp["is_mine"])
	}

	// User A 查询 -> has_pending=true, is_mine=true
	rA := gin.New()
	rA.GET("/posts/:id/featured-application-status", func(c *gin.Context) {
		c.Set("user_id", uint(1)) // User A
		handler.GetFeaturedApplicationStatus(c)
	})

	wA := httptest.NewRecorder()
	reqA, _ := http.NewRequest("GET", "/posts/100/featured-application-status", nil)
	rA.ServeHTTP(wA, reqA)

	var respA map[string]interface{}
	json.Unmarshal(wA.Body.Bytes(), &respA)

	if respA["has_pending"] != true || respA["is_mine"] != true {
		t.Fatalf("expected has_pending true and is_mine true for User A, got %v", respA)
	}

	// DB 错误场景（删除表模拟报错） -> 必须返回 500，不能假装 false
	db.Exec("DROP TABLE featured_applications")
	wErr := httptest.NewRecorder()
	reqErr, _ := http.NewRequest("GET", "/posts/100/featured-application-status", nil)
	rA.ServeHTTP(wErr, reqErr)

	if wErr.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500 on DB error, got %d", wErr.Code)
	}
}

// 3. 测试取消版块精华联动将版主自动推荐标记为 withdrawn，而不影响用户申请
func TestWaterModeration_UnfeaturePost_WithdrawsPendingModeratorApp(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newFeaturedTestDB(t)
	modHandler := NewWaterModerationHandler(db)

	section := models.WaterSection{Slug: "campus", Title: "校园", Status: "active"}
	db.Create(&section)

	operator := models.User{StudentID: "mod1", Role: models.RoleUser}
	db.Create(&operator)

	mod := models.WaterSectionModerator{SectionID: section.ID, UserID: operator.ID, CanPinPost: true}
	db.Create(&mod)

	post := models.Post{Title: "Featured Post", PostType: "campus", BoardID: models.BoardShuitie, Status: models.PostStatusNormal}
	db.Create(&post)

	featured := models.WaterSectionFeaturedPost{
		SectionID:  section.ID,
		PostID:     post.ID,
		FeaturedBy: operator.ID,
		Reason:     "Good post",
		Status:     models.SectionFeaturedStatusActive,
	}
	db.Create(&featured)

	// 版主自动生成的 pending 推荐
	modApp := models.FeaturedApplication{
		PostID:            post.ID,
		ApplicantID:       operator.ID,
		Source:            "moderator",
		SectionID:         &section.ID,
		SectionFeaturedID: &featured.ID,
		Reason:            "版主推荐",
		Status:            "pending",
	}
	db.Create(&modApp)

	// 普通用户自行提交的 pending 申请
	userApp := models.FeaturedApplication{
		PostID:      post.ID,
		ApplicantID: 999,
		Source:      "user",
		Reason:      "自荐",
		Status:      "pending",
	}
	db.Create(&userApp)

	// 执行取消版块精华
	r := gin.New()
	r.DELETE("/api/water/sections/:slug/posts/:post_id/feature", func(c *gin.Context) {
		c.Set("user_id", operator.ID)
		modHandler.UnfeaturePost(c)
	})

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("DELETE", fmt.Sprintf("/api/water/sections/campus/posts/%d/feature", post.ID), nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected status 200 on unfeature, got %d", w.Code)
	}

	// 校验版主自动推荐被标记为 withdrawn
	var updatedModApp models.FeaturedApplication
	db.First(&updatedModApp, modApp.ID)
	if updatedModApp.Status != "withdrawn" {
		t.Fatalf("expected moderator app status to be withdrawn, got %s", updatedModApp.Status)
	}

	// 校验用户自行申请不受影响，仍保持 pending
	var updatedUserApp models.FeaturedApplication
	db.First(&updatedUserApp, userApp.ID)
	if updatedUserApp.Status != "pending" {
		t.Fatalf("expected user app status to stay pending, got %s", updatedUserApp.Status)
	}
}

// 4. 测试 ensureHomeFeaturedApplication 已存在 pending 时的复用
func TestEnsureHomeFeaturedApplication_ReuseExistingPending(t *testing.T) {
	db := newFeaturedTestDB(t)
	modHandler := NewWaterModerationHandler(db)

	existing := models.FeaturedApplication{
		PostID:      50,
		ApplicantID: 10,
		Source:      "user",
		Status:      "pending",
	}
	db.Create(&existing)

	app, err := modHandler.ensureHomeFeaturedApplication(50, 20, 1, 100, "版主加精")
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if app.ID != existing.ID {
		t.Fatalf("expected existing app ID %d, got %d", existing.ID, app.ID)
	}
}

// 5. 测试 AdminGetFeaturedApplications 预加载 Post.Author
func TestAdminGetFeaturedApplications_PreloadPostAuthor(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newFeaturedTestDB(t)
	handler := &PostHandler{db: db}

	author := models.User{StudentID: "author1", Nickname: "张三"}
	db.Create(&author)

	post := models.Post{Title: "测试文章", AuthorID: author.ID}
	db.Create(&post)

	app := models.FeaturedApplication{PostID: post.ID, ApplicantID: author.ID, Status: "pending"}
	db.Create(&app)

	r := gin.New()
	r.GET("/admin/featured-applications", handler.AdminGetFeaturedApplications)

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("GET", "/admin/featured-applications?status=pending", nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", w.Code)
	}

	body := w.Body.String()
	if !strings.Contains(body, "张三") {
		t.Fatalf("expected response body to contain author nickname '张三', got: %s", body)
	}
}

// 6. 测试 FeaturePost 部分成功 (Partial Success 200 + warning)
func TestWaterModeration_FeaturePost_PartialSuccess(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newFeaturedTestDB(t)
	modHandler := NewWaterModerationHandler(db)

	section := models.WaterSection{Slug: "tech", Title: "科技", Status: "active"}
	db.Create(&section)

	operator := models.User{StudentID: "mod2", Role: models.RoleUser}
	db.Create(&operator)

	mod := models.WaterSectionModerator{SectionID: section.ID, UserID: operator.ID, CanPinPost: true}
	db.Create(&mod)

	post := models.Post{Title: "Tech Post", PostType: "tech", BoardID: models.BoardShuitie, Status: models.PostStatusNormal}
	db.Create(&post)

	// 删除 featured_applications 表模拟首页推荐提交失败
	db.Exec("DROP TABLE featured_applications")

	r := gin.New()
	r.POST("/api/water/sections/:slug/posts/:post_id/feature", func(c *gin.Context) {
		c.Set("user_id", operator.ID)
		modHandler.FeaturePost(c)
	})

	w := httptest.NewRecorder()
	reqBody, _ := json.Marshal(map[string]string{"reason": "优质科技帖"})
	req, _ := http.NewRequest("POST", fmt.Sprintf("/api/water/sections/tech/posts/%d/feature", post.ID), bytes.NewBuffer(reqBody))
	req.Header.Set("Content-Type", "application/json")
	r.ServeHTTP(w, req)

	// 应返回 HTTP 200 且包含 warning
	if w.Code != http.StatusOK {
		t.Fatalf("expected status 200 OK on partial success, got %d", w.Code)
	}

	var resp map[string]interface{}
	json.Unmarshal(w.Body.Bytes(), &resp)

	if resp["warning"] == nil || !strings.Contains(resp["warning"].(string), "首页推荐提交失败") {
		t.Fatalf("expected warning message in response, got %v", resp["warning"])
	}

	// 确认版块精华表成功新建且状态为 active
	var feat models.WaterSectionFeaturedPost
	if err := db.Where("section_id = ? AND post_id = ?", section.ID, post.ID).First(&feat).Error; err != nil {
		t.Fatalf("expected WaterSectionFeaturedPost to be created, got error: %v", err)
	}
	if feat.Status != models.SectionFeaturedStatusActive {
		t.Fatalf("expected featured status active, got %s", feat.Status)
	}
}

// 7. 测试 UnfeaturePost 事务异常时抛出 500
func TestWaterModeration_UnfeaturePost_TransactionError(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newFeaturedTestDB(t)
	modHandler := NewWaterModerationHandler(db)

	section := models.WaterSection{Slug: "news", Title: "新闻", Status: "active"}
	db.Create(&section)

	operator := models.User{StudentID: "mod3", Role: models.RoleUser}
	db.Create(&operator)

	mod := models.WaterSectionModerator{SectionID: section.ID, UserID: operator.ID, CanPinPost: true}
	db.Create(&mod)

	post := models.Post{Title: "News Post", PostType: "news", BoardID: models.BoardShuitie, Status: models.PostStatusNormal}
	db.Create(&post)

	featured := models.WaterSectionFeaturedPost{
		SectionID:  section.ID,
		PostID:     post.ID,
		FeaturedBy: operator.ID,
		Reason:     "News",
		Status:     models.SectionFeaturedStatusActive,
	}
	db.Create(&featured)

	// 删表导致事务失败
	db.Exec("DROP TABLE featured_applications")

	r := gin.New()
	r.DELETE("/api/water/sections/:slug/posts/:post_id/feature", func(c *gin.Context) {
		c.Set("user_id", operator.ID)
		modHandler.UnfeaturePost(c)
	})

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("DELETE", fmt.Sprintf("/api/water/sections/news/posts/%d/feature", post.ID), nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("expected status 500 on transaction failure, got %d", w.Code)
	}
}
