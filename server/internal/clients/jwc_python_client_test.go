package clients

import (
	"testing"
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

func TestValidateCrawlItem(t *testing.T) {
	// Valid item
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

	// Invalid source
	invalid := *valid
	invalid.Source = "other"
	if err := ValidateCrawlItem(&invalid); err == nil {
		t.Error("should reject invalid source")
	}

	// Invalid category_slug
	invalid = *valid
	invalid.CategorySlug = "invalid"
	if err := ValidateCrawlItem(&invalid); err == nil {
		t.Error("should reject invalid category_slug")
	}

	// Invalid source_url
	invalid = *valid
	invalid.SourceURL = "https://evil.com/foo.htm"
	if err := ValidateCrawlItem(&invalid); err == nil {
		t.Error("should reject non-jwc source_url")
	}

	// Invalid content_hash (too short)
	invalid = *valid
	invalid.ContentHash = "abc"
	if err := ValidateCrawlItem(&invalid); err == nil {
		t.Error("should reject invalid content_hash")
	}

	// Invalid content_hash (wrong chars)
	invalid = *valid
	invalid.ContentHash = "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"
	if err := ValidateCrawlItem(&invalid); err == nil {
		t.Error("should reject non-hex content_hash")
	}
}
