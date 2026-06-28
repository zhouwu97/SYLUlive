package clients

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestValidateJWCURL(t *testing.T) {
	tests := []struct {
		name    string
		url     string
		wantErr bool
	}{
		{"valid article URL", "https://jwc.sylu.edu.cn/info/1116/5946.htm", false},
		{"valid attachment URL", "https://jwc.sylu.edu.cn/system/_content/download.jsp?wbfileid=1", false},
		{"http not allowed", "http://jwc.sylu.edu.cn/info/1116/5946.htm", true},
		{"wrong host", "https://evil.com/info/1116/5946.htm", true},
		{"subdomain spoof", "https://jwc.sylu.edu.cn.attacker.com/info/1116/5946.htm", true},
		{"userinfo not allowed", "https://user:pass@jwc.sylu.edu.cn/info/1116/5946.htm", true},
		{"javascript scheme", "javascript:alert(1)", true},
		{"empty URL", "", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateJWCURL(tt.url)
			if (err != nil) != tt.wantErr {
				t.Errorf("validateJWCURL(%q) error=%v wantErr=%v", tt.url, err, tt.wantErr)
			}
		})
	}
}

func TestValidateCampusURL(t *testing.T) {
	tests := []struct {
		name        string
		url         string
		allowedHost string
		wantErr     bool
	}{
		// JWC host
		{"jwc valid", "https://jwc.sylu.edu.cn/info/1116/5946.htm", "jwc.sylu.edu.cn", false},
		{"jwc wrong host", "https://cxcyxy.sylu.edu.cn/info/1089/3293.htm", "jwc.sylu.edu.cn", true},
		// Competition host
		{"cxcy valid", "https://cxcyxy.sylu.edu.cn/info/1089/3293.htm", "cxcyxy.sylu.edu.cn", false},
		{"cxcy valid attachment", "https://cxcyxy.sylu.edu.cn/system/_content/download.jsp?wbfileid=1", "cxcyxy.sylu.edu.cn", false},
		{"cxcy wrong host", "https://jwc.sylu.edu.cn/info/1089/3293.htm", "cxcyxy.sylu.edu.cn", true},
		// Common rejections
		{"http rejected", "http://cxcyxy.sylu.edu.cn/info/1089/3293.htm", "cxcyxy.sylu.edu.cn", true},
		{"userinfo rejected", "https://user:pass@cxcyxy.sylu.edu.cn/info/1089/3293.htm", "cxcyxy.sylu.edu.cn", true},
		{"non-standard port rejected", "https://cxcyxy.sylu.edu.cn:8080/info/1089/3293.htm", "cxcyxy.sylu.edu.cn", true},
		{"standard port 443 allowed", "https://cxcyxy.sylu.edu.cn:443/info/1089/3293.htm", "cxcyxy.sylu.edu.cn", false},
		{"evil subdomain rejected", "https://evil.cxcyxy.sylu.edu.cn/info/1089/3293.htm", "cxcyxy.sylu.edu.cn", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateCampusURL(tt.url, tt.allowedHost)
			if (err != nil) != tt.wantErr {
				t.Errorf("validateCampusURL(%q, %q) error=%v wantErr=%v", tt.url, tt.allowedHost, err, tt.wantErr)
			}
		})
	}
}

func TestValidateCrawlItem(t *testing.T) {
	valid := &CrawlItem{
		Source:           "jwc",
		Category:         "教务通知",
		CategorySlug:     "jwtz",
		CategoryID:       "1116",
		SourceArticleID:  "5946",
		SourceURL:        "https://jwc.sylu.edu.cn/info/1116/5946.htm",
		Title:            "Test Title",
		PublishDate:      "2026-06-23",
		AuthorDepartment: "教务管理科",
		ContentHTML:      "<p>test</p>",
		ContentText:      "test",
		Attachments:      []AttachmentItem{},
		HasAttachment:    false,
		ContentHash:      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	}

	if err := ValidateCrawlItem(valid); err != nil {
		t.Errorf("valid item should pass: %v", err)
	}

	invalid := *valid
	invalid.Source = "other"
	if err := ValidateCrawlItem(&invalid); err == nil {
		t.Error("should reject invalid source")
	}

	invalid = *valid
	invalid.CategorySlug = "invalid"
	if err := ValidateCrawlItem(&invalid); err == nil {
		t.Error("should reject invalid category_slug")
	}

	invalid = *valid
	invalid.SourceURL = "https://evil.com/foo.htm"
	if err := ValidateCrawlItem(&invalid); err == nil {
		t.Error("should reject non-jwc source_url")
	}

	invalid = *valid
	invalid.ContentHash = "abc"
	if err := ValidateCrawlItem(&invalid); err == nil {
		t.Error("should reject invalid content_hash")
	}

	invalid = *valid
	invalid.ContentHash = "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"
	if err := ValidateCrawlItem(&invalid); err == nil {
		t.Error("should reject non-hex content_hash")
	}
}

func TestValidateCrawlItemCompetition(t *testing.T) {
	valid := &CrawlItem{
		Source:           "cxcy",
		Category:         "比赛通知",
		CategorySlug:     "competition",
		CategoryID:       "1089",
		SourceArticleID:  "3293",
		SourceURL:        "https://cxcyxy.sylu.edu.cn/info/1089/3293.htm",
		Title:            "Test Competition Title",
		PublishDate:      "2026-06-28",
		AuthorDepartment: "创新创业学院",
		ContentHTML:      "<p>test</p>",
		ContentText:      "test",
		Attachments:      []AttachmentItem{},
		HasAttachment:    false,
		ContentHash:      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	}

	// Valid cxcy + competition
	if err := ValidateCrawlItem(valid); err != nil {
		t.Errorf("valid competition item should pass: %v", err)
	}

	// cxcy + jwtz → should be rejected (cross-source category)
	invalid := *valid
	invalid.CategorySlug = "jwtz"
	if err := ValidateCrawlItem(&invalid); err == nil {
		t.Error("should reject cxcy + jwtz (cross-source category)")
	}

	// jwc + competition → should be rejected (cross-source category)
	invalid = *valid
	invalid.Source = "jwc"
	invalid.SourceURL = "https://jwc.sylu.edu.cn/info/1116/5946.htm"
	invalid.CategorySlug = "competition"
	if err := ValidateCrawlItem(&invalid); err == nil {
		t.Error("should reject jwc + competition (cross-source category)")
	}

	// cxcy + jwc host → should be rejected (host mismatch)
	invalid = *valid
	invalid.SourceURL = "https://jwc.sylu.edu.cn/info/1089/3293.htm"
	if err := ValidateCrawlItem(&invalid); err == nil {
		t.Error("should reject cxcy item with jwc.sylu.edu.cn URL")
	}

	// jwc + cxcy host → should be rejected (host mismatch)
	jwcItem := &CrawlItem{
		Source:       "jwc",
		CategorySlug: "jwtz",
		SourceURL:    "https://cxcyxy.sylu.edu.cn/info/1116/5946.htm",
		Title:        "test",
		PublishDate:  "2026-06-28",
		ContentHash:  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	}
	if err := ValidateCrawlItem(jwcItem); err == nil {
		t.Error("should reject jwc item with cxcyxy.sylu.edu.cn URL")
	}

	// Unknown source → should be rejected
	invalid = *valid
	invalid.Source = "unknown"
	if err := ValidateCrawlItem(&invalid); err == nil {
		t.Error("should reject unknown source")
	}

	// cxcy attachment with wrong host → should be rejected
	invalid = *valid
	invalid.Attachments = []AttachmentItem{
		{Name: "test.pdf", URL: "https://evil.com/download.jsp", Extension: "pdf"},
	}
	if err := ValidateCrawlItem(&invalid); err == nil {
		t.Error("should reject cxcy item with non-cxcyxy attachment URL")
	}
}

// ── HTTP-level retry tests with httptest.Server ────────────────────

func TestCrawlHTTP401NoRetry(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer ts.Close()

	client := NewJWCPythonClient(ts.URL, "test-token")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := client.Crawl(ctx, &CrawlRequest{
		Categories: []string{"jwtz"},
		MaxPages:   1,
	})
	if err == nil {
		t.Fatal("expected error for 401")
	}
	if !strings.Contains(err.Error(), "401") {
		t.Errorf("expected 401 in error, got: %v", err)
	}
}

func TestCrawlHTTP503Retries(t *testing.T) {
	count := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count++
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer ts.Close()

	client := NewJWCPythonClient(ts.URL, "test-token")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, err := client.Crawl(ctx, &CrawlRequest{
		Categories: []string{"jwtz"},
		MaxPages:   1,
	})
	if err == nil {
		t.Fatal("expected error for persistent 503")
	}
	if count < 2 {
		t.Errorf("expected at least 2 attempts (retry), got %d", count)
	}
}

func TestCrawlContextCancel(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(5 * time.Second)
		w.WriteHeader(http.StatusOK)
	}))
	defer ts.Close()

	client := NewJWCPythonClient(ts.URL, "test-token")
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	_, err := client.Crawl(ctx, &CrawlRequest{
		Categories: []string{"jwtz"},
		MaxPages:   1,
	})
	if err == nil {
		t.Fatal("expected context error")
	}
}

func TestCrawlHTTP200Success(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{
			"success": true,
			"generated_at": "2026-06-25T20:00:00+08:00",
			"items": [],
			"stats": {
				"categories_requested": 1,
				"pages_fetched": 1,
				"list_items_seen": 0,
				"article_details_fetched": 0,
				"stop_reason": "max_pages_reached",
				"partial_failure": false
			},
			"errors": []
		}`))
	}))
	defer ts.Close()

	client := NewJWCPythonClient(ts.URL, "test-token")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	resp, err := client.Crawl(ctx, &CrawlRequest{
		Categories: []string{"jwtz"},
		MaxPages:   1,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !resp.Success {
		t.Error("expected success")
	}
}

func TestCrawlHTTP409Retry(t *testing.T) {
	count := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count++
		if count == 1 {
			w.WriteHeader(http.StatusConflict)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{
			"success": true,
			"generated_at": "2026-06-25T20:00:00+08:00",
			"items": [],
			"stats": {
				"categories_requested": 1,
				"pages_fetched": 0,
				"list_items_seen": 0,
				"article_details_fetched": 0,
				"stop_reason": "max_pages_reached",
				"partial_failure": false
			},
			"errors": []
		}`))
	}))
	defer ts.Close()

	client := NewJWCPythonClient(ts.URL, "test-token")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	resp, err := client.Crawl(ctx, &CrawlRequest{
		Categories: []string{"jwtz"},
		MaxPages:   1,
	})
	if err != nil {
		t.Fatalf("unexpected error after 409 retry: %v", err)
	}
	if !resp.Success {
		t.Error("expected success after 409 retry")
	}
	if count != 2 {
		t.Errorf("expected 2 attempts (409 + retry), got %d", count)
	}
}
