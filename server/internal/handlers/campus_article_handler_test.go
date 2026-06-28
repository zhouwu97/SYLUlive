package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"

	"gorm.io/datatypes"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func setupTestDB(t *testing.T) *gorm.DB {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if err := db.AutoMigrate(&models.CampusArticle{}, &models.JWCSyncState{}); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return db
}

func TestListEmpty(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := setupTestDB(t)

	handler := &CampusArticleHandler{db: db}

	r := gin.New()
	r.GET("/articles", handler.List)

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("GET", "/articles", nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp ListResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(resp.Items) != 0 {
		t.Errorf("expected 0 items, got %d", len(resp.Items))
	}
	if resp.HasMore {
		t.Error("empty DB should not have more")
	}
}

func TestListWithData(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := setupTestDB(t)

	// Seed data
	attJSON := datatypes.JSON([]byte("[]"))
	articles := []models.CampusArticle{
		{
			Source: "jwc", Category: "教务通知", CategorySlug: "jwtz",
			CategoryID: "1116", SourceArticleID: "5946",
			SourceURL: "https://jwc.sylu.edu.cn/info/1116/5946.htm",
			Title:     "Test Article 1", ContentHash: "a" + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			Attachments: attJSON, IsInitialImport: true,
		},
		{
			Source: "jwc", Category: "教务公告", CategorySlug: "jwgg",
			CategoryID: "1119", SourceArticleID: "5903",
			SourceURL: "https://jwc.sylu.edu.cn/info/1119/5903.htm",
			Title:     "Test Article 2", ContentHash: "b" + "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
			Attachments: attJSON, IsInitialImport: true,
		},
	}
	for _, a := range articles {
		db.Create(&a)
	}

	handler := &CampusArticleHandler{db: db}
	r := gin.New()
	r.GET("/articles", handler.List)

	// All articles
	w := httptest.NewRecorder()
	req, _ := http.NewRequest("GET", "/articles", nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}
	var resp ListResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	if len(resp.Items) != 2 {
		t.Errorf("expected 2 items, got %d", len(resp.Items))
	}

	// Filter by category
	w = httptest.NewRecorder()
	req, _ = http.NewRequest("GET", "/articles?category=jwtz", nil)
	r.ServeHTTP(w, req)
	json.Unmarshal(w.Body.Bytes(), &resp)
	if len(resp.Items) != 1 {
		t.Errorf("expected 1 jwtz item, got %d", len(resp.Items))
	}

	// Pagination
	w = httptest.NewRecorder()
	req, _ = http.NewRequest("GET", "/articles?page=1&page_size=1", nil)
	r.ServeHTTP(w, req)
	json.Unmarshal(w.Body.Bytes(), &resp)
	if len(resp.Items) != 1 {
		t.Errorf("expected 1 item with page_size=1, got %d", len(resp.Items))
	}
	if !resp.HasMore {
		t.Error("expected has_more=true")
	}
}

func TestListInvalidCategoryReturns400(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := setupTestDB(t)

	handler := &CampusArticleHandler{db: db}
	r := gin.New()
	r.GET("/articles", handler.List)

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("GET", "/articles?category=invalid", nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for invalid category, got %d", w.Code)
	}
}

func TestListWithCompetitionData(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := setupTestDB(t)

	attJSON := datatypes.JSON([]byte("[]"))
	// Seed both JWC and competition articles
	db.Create(&models.CampusArticle{
		Source: "jwc", Category: "教务通知", CategorySlug: "jwtz",
		CategoryID: "1116", SourceArticleID: "5946",
		SourceURL: "https://jwc.sylu.edu.cn/info/1116/5946.htm",
		Title:     "JWC Article", ContentHash: "a" + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		Attachments: attJSON,
	})
	db.Create(&models.CampusArticle{
		Source: "cxcy", Category: "比赛通知", CategorySlug: "competition",
		CategoryID: "1089", SourceArticleID: "3293",
		SourceURL: "https://cxcyxy.sylu.edu.cn/info/1089/3293.htm",
		Title:     "Competition Article", ContentHash: "b" + "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		Attachments: attJSON,
	})

	handler := &CampusArticleHandler{db: db}
	r := gin.New()
	r.GET("/articles", handler.List)

	// No filter → both JWC and cxcy
	w := httptest.NewRecorder()
	req, _ := http.NewRequest("GET", "/articles", nil)
	r.ServeHTTP(w, req)

	var resp ListResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	if len(resp.Items) != 2 {
		t.Errorf("expected 2 items (jwc + cxcy), got %d", len(resp.Items))
	}

	// Filter by competition
	w = httptest.NewRecorder()
	req, _ = http.NewRequest("GET", "/articles?category=competition", nil)
	r.ServeHTTP(w, req)
	json.Unmarshal(w.Body.Bytes(), &resp)
	if len(resp.Items) != 1 {
		t.Errorf("expected 1 competition item, got %d", len(resp.Items))
	}
	if resp.Items[0].Source != "cxcy" {
		t.Errorf("expected source=cxcy, got %q", resp.Items[0].Source)
	}
	if resp.Items[0].CategorySlug != "competition" {
		t.Errorf("expected category_slug=competition, got %q", resp.Items[0].CategorySlug)
	}
}

func TestGetDetail(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := setupTestDB(t)

	attJSON := datatypes.JSON([]byte(`[{"name":"test.xls","url":"https://jwc.sylu.edu.cn/system/_content/download.jsp?wbfileid=1","extension":"xls"}]`))
	article := models.CampusArticle{
		Source: "jwc", Category: "教务通知", CategorySlug: "jwtz",
		CategoryID: "1116", SourceArticleID: "5946",
		SourceURL: "https://jwc.sylu.edu.cn/info/1116/5946.htm",
		Title:     "Detail Article", ContentHash: "c" + "ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
		ContentHTML: "<p>Full content</p>", ContentText: "Full content",
		Attachments: attJSON, HasAttachment: true,
	}
	db.Create(&article)

	handler := &CampusArticleHandler{db: db}
	r := gin.New()
	r.GET("/articles/:id", handler.GetDetail)

	// Valid ID
	w := httptest.NewRecorder()
	req, _ := http.NewRequest("GET", "/articles/1", nil)
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}

	var resp struct {
		Item DetailItem `json:"item"`
	}
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp.Item.Title != "Detail Article" {
		t.Errorf("expected 'Detail Article', got %q", resp.Item.Title)
	}
	if len(resp.Item.Attachments) == 0 {
		t.Error("expected attachments in detail")
	}

	// Invalid ID (non-numeric)
	w = httptest.NewRecorder()
	req, _ = http.NewRequest("GET", "/articles/abc", nil)
	r.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", w.Code)
	}

	// Not found
	w = httptest.NewRecorder()
	req, _ = http.NewRequest("GET", "/articles/99999", nil)
	r.ServeHTTP(w, req)
	if w.Code != http.StatusNotFound {
		t.Errorf("expected 404, got %d", w.Code)
	}
}

func TestGetDetailCompetition(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := setupTestDB(t)

	attJSON := datatypes.JSON([]byte("[]"))
	article := models.CampusArticle{
		Source: "cxcy", Category: "比赛通知", CategorySlug: "competition",
		CategoryID: "1089", SourceArticleID: "3293",
		SourceURL: "https://cxcyxy.sylu.edu.cn/info/1089/3293.htm",
		Title:     "Competition Detail", ContentHash: "d" + "ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
		ContentHTML: "<p>Competition content</p>", ContentText: "Competition content",
		Attachments: attJSON,
	}
	db.Create(&article)

	handler := &CampusArticleHandler{db: db}
	r := gin.New()
	r.GET("/articles/:id", handler.GetDetail)

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("GET", "/articles/1", nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200 for cxcy article, got %d", w.Code)
	}

	var resp struct {
		Item DetailItem `json:"item"`
	}
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp.Item.Source != "cxcy" {
		t.Errorf("expected source=cxcy, got %q", resp.Item.Source)
	}
	if resp.Item.CategorySlug != "competition" {
		t.Errorf("expected category_slug=competition, got %q", resp.Item.CategorySlug)
	}
}

func TestGetLatest(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := setupTestDB(t)

	handler := &CampusArticleHandler{db: db}
	r := gin.New()
	r.GET("/articles/latest", handler.GetLatest)

	// Empty DB
	w := httptest.NewRecorder()
	req, _ := http.NewRequest("GET", "/articles/latest", nil)
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("expected 200 for empty, got %d", w.Code)
	}
}

func TestGetLatestReturnsCompetition(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := setupTestDB(t)

	attJSON := datatypes.JSON([]byte("[]"))
	// JWC article (older)
	db.Create(&models.CampusArticle{
		Source: "jwc", Category: "教务通知", CategorySlug: "jwtz",
		CategoryID: "1116", SourceArticleID: "5946",
		SourceURL: "https://jwc.sylu.edu.cn/info/1116/5946.htm",
		Title:     "Older JWC Article", ContentHash: "a" + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		Attachments: attJSON,
	})
	// Competition article (newer)
	db.Create(&models.CampusArticle{
		Source: "cxcy", Category: "比赛通知", CategorySlug: "competition",
		CategoryID: "1089", SourceArticleID: "3293",
		SourceURL: "https://cxcyxy.sylu.edu.cn/info/1089/3293.htm",
		Title:     "Newer Competition Article", ContentHash: "b" + "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		Attachments: attJSON,
	})

	handler := &CampusArticleHandler{db: db}
	r := gin.New()
	r.GET("/articles/latest", handler.GetLatest)

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("GET", "/articles/latest", nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}

	var resp struct {
		Item *DetailItem `json:"item"`
	}
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp.Item == nil {
		t.Fatal("expected non-nil item")
	}
	if resp.Item.Source != "cxcy" {
		t.Errorf("expected latest to be cxcy (newer), got source=%q", resp.Item.Source)
	}
}
