package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// allowedCampusSources is the whitelist of approved article sources.
var allowedCampusSources = []string{"jwc", "cxcy"}

// allowedCampusCategories is the whitelist of approved category slugs.
var allowedCampusCategories = map[string]bool{
	"jwtz":        true,
	"jwgg":        true,
	"competition": true,
}

// CampusArticleHandler handles campus article read-only API requests.
type CampusArticleHandler struct {
	db           *gorm.DB
	syncServices []*services.CampusSyncService
}

// NewCampusArticleHandler creates a new campus article handler.
// Accepts variadic sync services for LastSyncAt aggregation.
func NewCampusArticleHandler(db *gorm.DB, syncServices ...*services.CampusSyncService) *CampusArticleHandler {
	return &CampusArticleHandler{db: db, syncServices: syncServices}
}

// ── List ──────────────────────────────────────────────────────────

// ListArticleItem is a lightweight article representation without full content.
type ListArticleItem struct {
	ID               uint   `json:"id"`
	Source           string `json:"source"`
	Category         string `json:"category"`
	CategorySlug     string `json:"category_slug"`
	CategoryID       string `json:"category_id"`
	SourceArticleID  string `json:"source_article_id"`
	SourceURL        string `json:"source_url"`
	Title            string `json:"title"`
	PublishDate      string `json:"publish_date"`
	AuthorDepartment string `json:"author_department"`
	HasAttachment    bool   `json:"has_attachment"`
	CreatedAt        string `json:"created_at"`
}

// ListResponse is the response for GET /api/campus/articles.
type ListResponse struct {
	Items      []ListArticleItem `json:"items"`
	Page       int               `json:"page"`
	PageSize   int               `json:"page_size"`
	HasMore    bool              `json:"has_more"`
	LastSyncAt *string           `json:"last_sync_at"`
}

// List returns paginated campus articles from all approved sources.
func (h *CampusArticleHandler) List(c *gin.Context) {
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "20"))
	category := c.Query("category")

	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 50 {
		pageSize = 20
	}

	query := h.db.Model(&models.CampusArticle{}).
		Where("source IN ?", allowedCampusSources)

	if category != "" {
		if !allowedCampusCategories[category] {
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效的分类"})
			return
		}
		query = query.Where("category_slug = ?", category)
	}

	// 先统计总数（用于 has_more）
	var total int64
	query.Count(&total)

	var articles []models.CampusArticle
	offset := (page - 1) * pageSize
	if err := query.
		Order("publish_date DESC, id DESC").
		Limit(pageSize + 1). // 多取一条判断 has_more
		Offset(offset).
		Find(&articles).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}

	hasMore := len(articles) > pageSize
	if hasMore {
		articles = articles[:pageSize]
	}

	items := make([]ListArticleItem, len(articles))
	for i, a := range articles {
		items[i] = ListArticleItem{
			ID:               a.ID,
			Source:           a.Source,
			Category:         a.Category,
			CategorySlug:     a.CategorySlug,
			CategoryID:       a.CategoryID,
			SourceArticleID:  a.SourceArticleID,
			SourceURL:        a.SourceURL,
			Title:            a.Title,
			PublishDate:      a.PublishDate.Format("2006-01-02"),
			AuthorDepartment: a.AuthorDepartment,
			HasAttachment:    a.HasAttachment,
			CreatedAt:        a.CreatedAt.Format("2006-01-02T15:04:05+08:00"),
		}
	}

	lastSyncAt := h.aggregateLastSyncAt()

	c.JSON(http.StatusOK, ListResponse{
		Items:      items,
		Page:       page,
		PageSize:   pageSize,
		HasMore:    hasMore,
		LastSyncAt: lastSyncAt,
	})
}

// ── GetLatest ─────────────────────────────────────────────────────

// GetLatest returns the most recent article from all approved sources.
func (h *CampusArticleHandler) GetLatest(c *gin.Context) {
	var article models.CampusArticle
	if err := h.db.Where("source IN ?", allowedCampusSources).
		Order("publish_date DESC, id DESC").
		First(&article).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusOK, gin.H{"item": nil})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"item": toDetailItem(&article)})
}

// ── GetDetail ─────────────────────────────────────────────────────

// DetailItem is the full article representation with content and attachments.
type DetailItem struct {
	ID               uint            `json:"id"`
	Source           string          `json:"source"`
	Category         string          `json:"category"`
	CategorySlug     string          `json:"category_slug"`
	CategoryID       string          `json:"category_id"`
	SourceArticleID  string          `json:"source_article_id"`
	SourceURL        string          `json:"source_url"`
	Title            string          `json:"title"`
	PublishDate      string          `json:"publish_date"`
	AuthorDepartment string          `json:"author_department"`
	ContentHTML      string          `json:"content_html"`
	ContentText      string          `json:"content_text"`
	Attachments      json.RawMessage `json:"attachments"`
	HasAttachment    bool            `json:"has_attachment"`
	CreatedAt        string          `json:"created_at"`
	UpdatedAt        string          `json:"updated_at"`
}

// GetDetail returns a single article with full content.
// Source whitelist prevents reading articles from unapproved sources.
func (h *CampusArticleHandler) GetDetail(c *gin.Context) {
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的文章 ID"})
		return
	}

	var article models.CampusArticle
	if err := h.db.Where("source IN ?", allowedCampusSources).
		First(&article, id).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, gin.H{"error": "文章不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"item": toDetailItem(&article)})
}

// ── helpers ───────────────────────────────────────────────────────

// aggregateLastSyncAt returns the most recent sync time across all services.
// Nil-safe: returns nil when no services or no sync has occurred.
func (h *CampusArticleHandler) aggregateLastSyncAt() *string {
	var latest *time.Time
	for _, svc := range h.syncServices {
		if svc == nil {
			continue
		}
		if t := svc.LastSyncAt(); t != nil {
			if latest == nil || t.After(*latest) {
				latest = t
			}
		}
	}
	if latest == nil {
		return nil
	}
	s := latest.Format("2006-01-02T15:04:05+08:00")
	return &s
}

func toDetailItem(a *models.CampusArticle) DetailItem {
	att := json.RawMessage(a.Attachments)
	if att == nil {
		att = json.RawMessage([]byte("[]"))
	}
	return DetailItem{
		ID:               a.ID,
		Source:           a.Source,
		Category:         a.Category,
		CategorySlug:     a.CategorySlug,
		CategoryID:       a.CategoryID,
		SourceArticleID:  a.SourceArticleID,
		SourceURL:        a.SourceURL,
		Title:            a.Title,
		PublishDate:      a.PublishDate.Format("2006-01-02"),
		AuthorDepartment: a.AuthorDepartment,
		ContentHTML:      a.ContentHTML,
		ContentText:      a.ContentText,
		Attachments:      att,
		HasAttachment:    a.HasAttachment,
		CreatedAt:        a.CreatedAt.Format("2006-01-02T15:04:05+08:00"),
		UpdatedAt:        a.UpdatedAt.Format("2006-01-02T15:04:05+08:00"),
	}
}
