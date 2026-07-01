package services

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"

	"gorm.io/datatypes"
	"gorm.io/gorm"

	"shenliyuan/internal/clients"
	"shenliyuan/internal/models"
)

// CrawlSourceSpec defines a campus article source for synchronization.
type CrawlSourceSpec struct {
	Source     string
	Categories []string
	// CrawlFunc calls the Python crawler endpoint for this source.
	// knownURLs is keyed by category slug; the function may flatten as needed.
	CrawlFunc func(ctx context.Context, knownURLs map[string][]string, maxPages int, reconcile bool) (*clients.CrawlResponse, error)
}

// CampusSyncService manages campus article synchronization for a single source.
type CampusSyncService struct {
	db   *gorm.DB
	spec CrawlSourceSpec
}

// JWCSyncService is a type alias for backward compatibility.
type JWCSyncService = CampusSyncService

// NewCampusSyncService creates a new sync service for the given source spec.
func NewCampusSyncService(db *gorm.DB, spec CrawlSourceSpec) *CampusSyncService {
	return &CampusSyncService{db: db, spec: spec}
}

// NewJWCSyncService creates a new sync service (backward-compatible wrapper).
func NewJWCSyncService(db *gorm.DB, spec CrawlSourceSpec) *JWCSyncService {
	return NewCampusSyncService(db, spec)
}

// SyncResult holds the outcome of a sync run.
type SyncResult struct {
	Added       int
	Updated     int
	Skipped     int
	Invalid     int
	IsBootstrap bool
	Error       error
	LastErrors  []string // first few structured error summaries
}

// Sync performs a full sync cycle: query known URLs, call Python, upsert.
func (s *CampusSyncService) Sync(ctx context.Context, reconcile bool, maxPages int) *SyncResult {
	result := &SyncResult{}
	src := s.spec.Source

	// Always update state on exit — registered before any DB/network call
	var partialFailure bool
	var itemCount int
	defer func() {
		s.updateSyncState(result, reconcile, partialFailure, itemCount)
	}()

	// ── 1. Determine bootstrap status ──────────────────
	var count int64
	if err := s.db.Model(&models.CampusArticle{}).
		Where("source = ?", src).Count(&count).Error; err != nil {
		result.Error = fmt.Errorf("count articles: %w", err)
		return result
	}
	result.IsBootstrap = count == 0

	// ── 2. Query known source URLs ─────────────────────
	knownURLs := s.queryKnownURLs()

	// ── 3. Call Python crawler via spec's CrawlFunc ────
	resp, err := s.spec.CrawlFunc(ctx, knownURLs, maxPages, reconcile)
	if err != nil {
		result.Error = fmt.Errorf("python crawl: %w", err)
		return result
	}

	partialFailure = resp.Stats.PartialFailure

	// Capture structured error summaries for state persistence
	const maxErrSummary = 3
	for i, e := range resp.Errors {
		if i >= maxErrSummary {
			break
		}
		result.LastErrors = append(result.LastErrors,
			fmt.Sprintf("%s/%s/%s", e.Category, e.Stage, e.Code))
	}

	// ── 4. Parse generated_at ──────────────────────────
	crawledAt := time.Now()
	if t, err := time.Parse(time.RFC3339, resp.GeneratedAt); err == nil {
		crawledAt = t
	}

	// ── 5. Validate and upsert each item ───────────────
	for i := range resp.Items {
		item := &resp.Items[i]
		if err := clients.ValidateCrawlItem(item); err != nil {
			log.Printf("[CAMPUS_SYNC:%s] invalid item skipped: %v (url=%s)", src, err, item.SourceURL)
			result.Invalid++
			continue
		}

		action, err := s.upsertArticle(item, crawledAt, result.IsBootstrap)
		if err != nil {
			log.Printf("[CAMPUS_SYNC:%s] upsert failed for %s: %v", src, item.SourceURL, err)
			result.Invalid++
			continue
		}

		switch action {
		case "added":
			result.Added++
		case "updated":
			result.Updated++
		case "skipped":
			result.Skipped++
		}
	}

	itemCount = len(resp.Items)

	log.Printf("[CAMPUS_SYNC:%s] done: added=%d updated=%d skipped=%d invalid=%d bootstrap=%v",
		src, result.Added, result.Updated, result.Skipped, result.Invalid,
		result.IsBootstrap)

	return result
}

// queryKnownURLs returns up to 200 known source URLs grouped by category slug.
func (s *CampusSyncService) queryKnownURLs() map[string][]string {
	src := s.spec.Source
	var articles []models.CampusArticle
	if err := s.db.Model(&models.CampusArticle{}).
		Where("source = ?", src).
		Order("id DESC").
		Limit(200).
		Find(&articles).Error; err != nil {
		log.Printf("[CAMPUS_SYNC:%s] query known URLs: %v", src, err)
		return nil
	}

	// Build a set of allowed categories for this source
	allowedCats := make(map[string]bool)
	for _, c := range s.spec.Categories {
		allowedCats[c] = true
	}

	result := make(map[string][]string)
	for _, a := range articles {
		slug := a.CategorySlug
		if !allowedCats[slug] {
			continue
		}
		result[slug] = append(result[slug], a.SourceURL)
	}
	return result
}

// upsertArticle inserts or updates a single campus article.
func (s *CampusSyncService) upsertArticle(
	item *clients.CrawlItem,
	crawledAt time.Time,
	isBootstrap bool,
) (string, error) {
	publishDate, err := time.Parse("2006-01-02", item.PublishDate)
	if err != nil {
		publishDate = time.Time{}
	}

	attachmentsJSON := datatypes.JSON([]byte("[]"))
	if len(item.Attachments) > 0 {
		if data, err := json.Marshal(item.Attachments); err == nil {
			attachmentsJSON = datatypes.JSON(data)
		}
	}

	now := time.Now()

	// Check if article exists by source_url
	var existing models.CampusArticle
	err = s.db.Where("source_url = ?", item.SourceURL).First(&existing).Error
	if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
		return "", fmt.Errorf("query existing: %w", err)
	}

	if existing.ID == 0 {
		// New article — use item.Source, not a hardcoded value
		article := models.CampusArticle{
			Source:           item.Source,
			Category:         item.Category,
			CategorySlug:     item.CategorySlug,
			CategoryID:       item.CategoryID,
			SourceArticleID:  item.SourceArticleID,
			SourceURL:        item.SourceURL,
			Title:            item.Title,
			PublishDate:      publishDate,
			AuthorDepartment: item.AuthorDepartment,
			ContentHTML:      item.ContentHTML,
			ContentText:      item.ContentText,
			Attachments:      attachmentsJSON,
			HasAttachment:    item.HasAttachment,
			ContentHash:      item.ContentHash,
			IsInitialImport:  isBootstrap,
			FirstSeenAt:      now,
			LastSeenAt:       now,
			SourceCrawledAt:  crawledAt,
		}
		if err := s.db.Create(&article).Error; err != nil {
			return "", fmt.Errorf("create article: %w", err)
		}
		return "added", nil
	}

	// Existing article
	if existing.ContentHash == item.ContentHash {
		_ = s.db.Model(&existing).Update("last_seen_at", now).Error
		return "skipped", nil
	}

	// Content changed — update
	updates := map[string]interface{}{
		"title":             item.Title,
		"publish_date":      publishDate,
		"author_department": item.AuthorDepartment,
		"content_html":      item.ContentHTML,
		"content_text":      item.ContentText,
		"attachments":       attachmentsJSON,
		"has_attachment":    item.HasAttachment,
		"content_hash":      item.ContentHash,
		"source_crawled_at": crawledAt,
		"last_seen_at":      now,
		"updated_at":        now,
	}
	if err := s.db.Model(&existing).Updates(updates).Error; err != nil {
		return "", fmt.Errorf("update article: %w", err)
	}
	return "updated", nil
}

// updateSyncState persists the sync outcome.
func (s *CampusSyncService) updateSyncState(
	result *SyncResult,
	reconcile bool,
	partialFailure bool,
	itemCount int,
) {
	src := s.spec.Source
	now := time.Now()

	var state models.JWCSyncState
	if err := s.db.Where("source = ?", src).First(&state).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			state = models.JWCSyncState{Source: src}
		} else {
			log.Printf("[CAMPUS_SYNC:%s] query sync state: %v", src, err)
			return
		}
	}

	state.LastAttemptAt = &now
	if result.Error == nil {
		if partialFailure {
			state.LastSuccessAt = &now
			state.LastItemCount = itemCount
			state.ConsecutiveFailures = 0
			state.LastError = formatPartialError(result, itemCount)
			if reconcile {
				state.LastReconcileAt = &now
			}
		} else {
			state.LastSuccessAt = &now
			state.LastItemCount = itemCount
			state.ConsecutiveFailures = 0
			state.LastError = ""
			if reconcile {
				state.LastReconcileAt = &now
			}
		}
	} else {
		state.ConsecutiveFailures++
		msg := result.Error.Error()
		if len(msg) > 500 {
			msg = msg[:500]
		}
		state.LastError = msg
	}

	_ = s.db.Save(&state).Error
}

// formatPartialError builds a structured error summary for partial failures.
func formatPartialError(result *SyncResult, itemCount int) string {
	base := fmt.Sprintf("partial failure: %d items saved", itemCount)
	if len(result.LastErrors) > 0 {
		base += "; " + strings.Join(result.LastErrors, ", ")
	}
	if len(base) > 500 {
		base = base[:500]
	}
	return base
}

// ShouldReconcile returns true if reconcile is due.
func (s *CampusSyncService) ShouldReconcile() bool {
	src := s.spec.Source
	var state models.JWCSyncState
	if err := s.db.Where("source = ?", src).First(&state).Error; err != nil {
		return true
	}
	if state.LastReconcileAt == nil {
		return true
	}
	return time.Since(*state.LastReconcileAt) > 24*time.Hour
}

// LastSyncAt returns the last successful sync time.
func (s *CampusSyncService) LastSyncAt() *time.Time {
	src := s.spec.Source
	var state models.JWCSyncState
	if err := s.db.Where("source = ?", src).First(&state).Error; err != nil {
		return nil
	}
	return state.LastSuccessAt
}
