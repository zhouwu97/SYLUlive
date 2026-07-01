package clients

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

const (
	jwcPythonTimeout = 90 * time.Second
	maxResponseSize  = 5 << 20 // 5 MB
)

// sha256Pattern matches a 64-character lowercase hex string.
var sha256Pattern = regexp.MustCompile(`^[a-f0-9]{64}$`)

// JWCPythonClient 调用国内 Python JWC 爬虫服务。
type JWCPythonClient struct {
	BaseURL string
	Token   string
}

// NewJWCPythonClient creates a new JWC Python API client.
func NewJWCPythonClient(baseURL, token string) *JWCPythonClient {
	return &JWCPythonClient{
		BaseURL: strings.TrimRight(baseURL, "/"),
		Token:   token,
	}
}

// ── request / response types ──────────────────────────────────────

// CrawlRequest is sent to Python's /api/internal/jwc/crawl endpoint.
type CrawlRequest struct {
	Categories      []string            `json:"categories"`
	KnownSourceURLs map[string][]string `json:"known_source_urls"`
	MaxPages        int                 `json:"max_pages"`
	Reconcile       bool                `json:"reconcile"`
}

// CompetitionCrawlRequest is sent to Python's /api/internal/campus/competition/crawl endpoint.
type CompetitionCrawlRequest struct {
	KnownSourceURLs []string `json:"known_source_urls"`
	MaxPages        int      `json:"max_pages"`
	Reconcile       bool     `json:"reconcile"`
}

// CrawlResponse is returned by Python's /api/internal/jwc/crawl endpoint.
type CrawlResponse struct {
	Success     bool             `json:"success"`
	GeneratedAt string           `json:"generated_at"`
	Items       []CrawlItem      `json:"items"`
	Stats       CrawlStats       `json:"stats"`
	Errors      []CrawlErrorItem `json:"errors"`
}

// CrawlItem represents one crawled article.
type CrawlItem struct {
	Source           string           `json:"source"`
	Category         string           `json:"category"`
	CategorySlug     string           `json:"category_slug"`
	CategoryID       string           `json:"category_id"`
	SourceArticleID  string           `json:"source_article_id"`
	SourceURL        string           `json:"source_url"`
	Title            string           `json:"title"`
	PublishDate      string           `json:"publish_date"`
	AuthorDepartment string           `json:"author_department"`
	ContentHTML      string           `json:"content_html"`
	ContentText      string           `json:"content_text"`
	Attachments      []AttachmentItem `json:"attachments"`
	HasAttachment    bool             `json:"has_attachment"`
	ContentHash      string           `json:"content_hash"`
}

// AttachmentItem represents an attachment in a crawled article.
type AttachmentItem struct {
	Name      string `json:"name"`
	URL       string `json:"url"`
	Extension string `json:"extension"`
}

// CrawlStats holds statistics about the crawl run.
type CrawlStats struct {
	CategoriesRequested   int    `json:"categories_requested"`
	PagesFetched          int    `json:"pages_fetched"`
	ListItemsSeen         int    `json:"list_items_seen"`
	ArticleDetailsFetched int    `json:"article_details_fetched"`
	StopReason            string `json:"stop_reason"`
	PartialFailure        bool   `json:"partial_failure"`
}

// CrawlErrorItem holds a structured crawl error.
type CrawlErrorItem struct {
	Category  string `json:"category"`
	Stage     string `json:"stage"`
	URL       string `json:"url"`
	Code      string `json:"code"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
}

// ── validation ────────────────────────────────────────────────────

// SourcePolicy defines the allowed host and categories for a given source.
type SourcePolicy struct {
	AllowedHost       string
	AllowedCategories map[string]bool
}

// sourcePolicies maps source identifiers to their validation policy.
var sourcePolicies = map[string]SourcePolicy{
	"jwc": {
		AllowedHost: "jwc.sylu.edu.cn",
		AllowedCategories: map[string]bool{
			"jwtz": true,
			"jwgg": true,
		},
	},
	"cxcy": {
		AllowedHost: "cxcyxy.sylu.edu.cn",
		AllowedCategories: map[string]bool{
			"competition": true,
		},
	},
}

// validateCampusURL checks that a URL uses https and targets the allowed host.
func validateCampusURL(rawURL string, allowedHost string) error {
	u, err := url.Parse(rawURL)
	if err != nil {
		return fmt.Errorf("invalid URL: %w", err)
	}
	if u.Scheme != "https" {
		return errors.New("URL scheme must be https")
	}
	if u.User != nil {
		return errors.New("userinfo is not allowed in URL")
	}
	if !strings.EqualFold(u.Hostname(), allowedHost) {
		return fmt.Errorf("URL host must be %s", allowedHost)
	}
	if port := u.Port(); port != "" && port != "443" {
		return errors.New("non-standard port is not allowed")
	}
	return nil
}

// validateJWCURL is a backward-compatible wrapper for JWC-specific validation.
func validateJWCURL(rawURL string) error {
	return validateCampusURL(rawURL, "jwc.sylu.edu.cn")
}

// ValidateCrawlItem performs per-article validation using source-aware policies.
func ValidateCrawlItem(item *CrawlItem) error {
	policy, ok := sourcePolicies[item.Source]
	if !ok {
		return fmt.Errorf("unsupported source %q", item.Source)
	}
	if !policy.AllowedCategories[item.CategorySlug] {
		return fmt.Errorf("category %q not allowed for source %q", item.CategorySlug, item.Source)
	}
	if err := validateCampusURL(item.SourceURL, policy.AllowedHost); err != nil {
		return fmt.Errorf("source_url: %w", err)
	}
	if len(item.SourceURL) > 2048 {
		return errors.New("source_url exceeds 2048 chars")
	}
	if len(item.Title) > 500 {
		return errors.New("title exceeds 500 chars")
	}
	if len(item.ContentHTML) > 1<<20 {
		return errors.New("content_html exceeds 1 MB")
	}
	if len(item.ContentText) > 500<<10 {
		return errors.New("content_text exceeds 500 KB")
	}
	if len(item.Attachments) > 20 {
		return errors.New("attachments exceed 20 per article")
	}
	for _, att := range item.Attachments {
		if len(att.Name) > 300 {
			return errors.New("attachment name exceeds 300 chars")
		}
		if len(att.URL) > 2048 {
			return errors.New("attachment URL exceeds 2048 chars")
		}
		if err := validateCampusURL(att.URL, policy.AllowedHost); err != nil {
			return fmt.Errorf("attachment URL: %w", err)
		}
	}
	if !sha256Pattern.MatchString(item.ContentHash) {
		return errors.New("content_hash must be 64-char hex SHA-256")
	}
	return nil
}

// ── HTTP call ─────────────────────────────────────────────────────

// Crawl calls the Python JWC crawl endpoint and returns the validated response.
// Retry policy:
//   - 400/401/403/422: no retry
//   - 409: single retry after 3s delay
//   - 502/503/504: up to 3 retries with exponential backoff
//   - Timeout/connection errors: up to 3 retries
func (c *JWCPythonClient) Crawl(ctx context.Context, req *CrawlRequest) (*CrawlResponse, error) {
	// Ensure KnownSourceURLs map is never nil — Python Pydantic rejects null
	if req.KnownSourceURLs == nil {
		req.KnownSourceURLs = make(map[string][]string)
	}
	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}
	apiURL := c.BaseURL + "/api/internal/jwc/crawl"
	return c.doCrawl(ctx, apiURL, body)
}

// CrawlCompetition calls the Python competition crawl endpoint.
func (c *JWCPythonClient) CrawlCompetition(ctx context.Context, req *CompetitionCrawlRequest) (*CrawlResponse, error) {
	// Ensure KnownSourceURLs is never nil — Python Pydantic rejects null, requires []
	if req.KnownSourceURLs == nil {
		req.KnownSourceURLs = make([]string, 0)
	}
	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}
	apiURL := c.BaseURL + "/api/internal/campus/competition/crawl"
	return c.doCrawl(ctx, apiURL, body)
}

// doCrawl performs the HTTP request with retry logic. Shared by Crawl and CrawlCompetition.
func (c *JWCPythonClient) doCrawl(ctx context.Context, apiURL string, body []byte) (*CrawlResponse, error) {
	var lastErr error
	for attempt := 0; attempt < 4; attempt++ {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}

		if attempt > 0 {
			wait := c.backoffWait(attempt)
			log.Printf("[CAMPUS_CLIENT] retry %d after %v", attempt, wait)
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(wait):
			}
		}

		resp, err := c.doRequest(ctx, apiURL, body)
		if err != nil {
			lastErr = err
			continue
		}

		// Handle response — must close Body on every non-200 path
		switch {
		case resp.StatusCode == http.StatusOK:
			return c.parseResponse(resp)

		case resp.StatusCode == http.StatusConflict: // 409
			drainAndClose(resp)
			if attempt == 0 {
				log.Println("[CAMPUS_CLIENT] crawl lock busy (409), retrying once after 3s")
				select {
				case <-ctx.Done():
					return nil, ctx.Err()
				case <-time.After(3 * time.Second):
				}
				attempt = 1 // skip: no backoff wait on next iteration
				continue
			}
			return nil, errors.New("crawl busy (409), giving up")

		case resp.StatusCode == http.StatusBadRequest,
			resp.StatusCode == http.StatusUnauthorized,
			resp.StatusCode == http.StatusForbidden,
			resp.StatusCode == http.StatusUnprocessableEntity:
			respBody := drainAndClose(resp)
			return nil, fmt.Errorf("crawl client error HTTP %d: %s", resp.StatusCode, respBody)

		case resp.StatusCode == http.StatusBadGateway,
			resp.StatusCode == http.StatusServiceUnavailable,
			resp.StatusCode == http.StatusGatewayTimeout:
			drainAndClose(resp)
			lastErr = fmt.Errorf("crawl upstream error HTTP %d", resp.StatusCode)
			continue

		default:
			if resp.StatusCode >= 400 && resp.StatusCode < 500 {
				respBody := drainAndClose(resp)
				return nil, fmt.Errorf("crawl HTTP %d: %s", resp.StatusCode, respBody)
			}
			drainAndClose(resp)
			lastErr = fmt.Errorf("crawl HTTP %d", resp.StatusCode)
			continue
		}
	}

	return nil, fmt.Errorf("crawl failed after retries: %w", lastErr)
}

// backoffWait returns the sleep duration for a given retry attempt.
func (c *JWCPythonClient) backoffWait(attempt int) time.Duration {
	w := time.Duration(1<<uint(attempt-1)) * time.Second
	if w > 8*time.Second {
		w = 8 * time.Second
	}
	return w
}

// drainAndClose reads and discards any remaining response body, then closes it.
// Must be called on every non-200 response to prevent connection leaks.
func drainAndClose(resp *http.Response) string {
	if resp == nil || resp.Body == nil {
		return ""
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	return string(data)
}

func (c *JWCPythonClient) doRequest(ctx context.Context, apiURL string, body []byte) (*http.Response, error) {
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, apiURL, strings.NewReader(string(body)))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+c.Token)

	client := &http.Client{
		Timeout: jwcPythonTimeout,
	}
	return client.Do(httpReq)
}

func (c *JWCPythonClient) parseResponse(resp *http.Response) (*CrawlResponse, error) {
	defer resp.Body.Close()

	// Read maxSize+1 to detect oversized responses
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseSize+1))
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	if len(data) > maxResponseSize {
		return nil, fmt.Errorf("response body exceeds max size (%d bytes)", maxResponseSize)
	}

	var result CrawlResponse
	if err := json.Unmarshal(data, &result); err != nil {
		return nil, fmt.Errorf("unmarshal response: %w", err)
	}

	// Validate response
	if len(result.Items) > 100 {
		return nil, fmt.Errorf("too many items in response: %d", len(result.Items))
	}
	if len(result.Errors) > 20 {
		result.Errors = result.Errors[:20]
	}

	// Validate generated_at has timezone
	if result.GeneratedAt != "" {
		if _, err := time.Parse(time.RFC3339, result.GeneratedAt); err != nil {
			log.Printf("[JWC_CLIENT] warning: generated_at not RFC3339: %q", result.GeneratedAt)
		}
	}

	return &result, nil
}
