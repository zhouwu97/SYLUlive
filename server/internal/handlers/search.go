package handlers

import (
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

type SearchHandler struct {
	db          *gorm.DB
	postHandler *PostHandler
	security    *services.SecurityEventService
	searchMu    sync.Mutex
	searchHits  map[string][]time.Time
}

func NewSearchHandler(db *gorm.DB, postHandler *PostHandler, security ...*services.SecurityEventService) *SearchHandler {
	var securityService *services.SecurityEventService
	if len(security) > 0 {
		securityService = security[0]
	}
	return &SearchHandler{db: db, postHandler: postHandler, security: securityService, searchHits: make(map[string][]time.Time)}
}

func (h *SearchHandler) Search(c *gin.Context) {
	queryText := strings.TrimSpace(c.Query("q"))
	if runeCount := utf8.RuneCountInString(queryText); runeCount < 2 || runeCount > 64 || onlySearchWildcards(queryText) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "搜索内容需为 2 至 64 个字符，不能只包含通配符"})
		return
	}
	if _, authenticated := c.Get("user_id"); !authenticated && !h.allowAnonymousSearch(c.ClientIP(), time.Now()) {
		if h.security != nil {
			_ = h.security.RecordContext(securityAuditContext(c), services.SecurityEventInput{
				EventType: "search_abuse", Severity: models.SecuritySeverityMedium,
				Route: "/api/search", Method: http.MethodGet, ClientIP: c.ClientIP(),
				TargetType: "route", TargetValue: "/api/search", TargetMasked: "/api/search",
				Blocked: true, Action: "throttled",
			})
		}
		c.Header("Retry-After", "60")
		c.JSON(http.StatusTooManyRequests, gin.H{"error": "搜索过于频繁，请稍后再试", "code": "search_rate_limited"})
		return
	}

	searchType := c.DefaultQuery("type", "posts")
	sort := c.DefaultQuery("sort", "relevance")
	page, limit, _ := ParsePagination(c, 20, 50)

	switch searchType {
	case "users":
		h.searchUsers(c, queryText, sort, page, limit)
	case "posts":
		h.searchPosts(c, queryText, sort, page, limit)
	default:
		c.JSON(http.StatusBadRequest, gin.H{"error": "不支持的搜索类型"})
	}
}

func parsePositiveInt(raw string, fallback int) int {
	value, err := strconv.Atoi(raw)
	if err != nil || value < 1 {
		return fallback
	}
	return value
}

func (h *SearchHandler) searchPosts(
	c *gin.Context,
	queryText string,
	sort string,
	page int,
	limit int,
) {
	searchText := strings.ToLower(queryText)
	searchLike := "%" + escapeSearchLikePattern(searchText) + "%"
	query := h.db.Model(&models.Post{}).
		Where("status = ?", models.PostStatusNormal).
		Where("(LOWER(title) LIKE ? ESCAPE '\\' OR LOWER(content) LIKE ? ESCAPE '\\')", searchLike, searchLike).
		Preload("Author").
		Preload("Images").
		Preload("Images.File").
		Scopes(withPostImageVariants)
	if !supportsPollRequest(c) {
		query = query.Where("content_kind <> ?", models.PostContentKindPoll)
	}

	if boardID := parsePositiveInt(c.Query("board"), 0); boardID > 0 {
		query = query.Where("board_id = ?", boardID)
	}

	switch sort {
	case "latest":
		query = query.Order("created_at DESC").Order("id DESC")
	case "hot":
		query = query.Order("(view_count + like_count * 20 + reply_count * 50) DESC").
			Order("created_at DESC")
	default:
		query = query.Order(clause.Expr{
			SQL: `CASE
				WHEN LOWER(title) = ? THEN 0
				WHEN LOWER(title) LIKE ? ESCAPE '\\' THEN 1
				WHEN LOWER(title) LIKE ? ESCAPE '\\' THEN 2
				WHEN LOWER(content) LIKE ? ESCAPE '\\' THEN 3
				ELSE 4
			END`,
			Vars: []interface{}{
				searchText,
				searchText + "%",
				searchLike,
				searchLike,
			},
		}).Order("created_at DESC")
	}

	var total int64
	if err := query.Count(&total).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "搜索帖子失败"})
		return
	}

	var posts []models.Post
	if err := query.Offset((page - 1) * limit).Limit(limit).Find(&posts).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "搜索帖子失败"})
		return
	}
	h.postHandler.hydratePosts(c, posts, time.Now())
	c.JSON(http.StatusOK, gin.H{
		"items": posts,
		"total": total,
		"page":  page,
		"limit": limit,
	})
}

func (h *SearchHandler) searchUsers(
	c *gin.Context,
	queryText string,
	sort string,
	page int,
	limit int,
) {
	searchText := strings.ToLower(queryText)
	searchLike := "%" + escapeSearchLikePattern(searchText) + "%"
	query := h.db.Model(&models.User{})

	parsedID, parseIDErr := strconv.ParseUint(queryText, 10, 64)
	if parseIDErr == nil {
		query = query.Where("id = ? OR LOWER(nickname) LIKE ? ESCAPE '\\'", parsedID, searchLike)
	} else {
		query = query.Where("LOWER(nickname) LIKE ? ESCAPE '\\'", searchLike)
	}

	if sort == "newest" {
		query = query.Order("created_at DESC")
	} else {
		if parseIDErr == nil {
			query = query.Order(clause.Expr{
				SQL: `CASE
					WHEN id = ? THEN 0
					WHEN LOWER(nickname) = ? THEN 1
					WHEN LOWER(nickname) LIKE ? ESCAPE '\\' THEN 2
					WHEN LOWER(nickname) LIKE ? ESCAPE '\\' THEN 3
					ELSE 4
				END`,
				Vars: []interface{}{
					parsedID,
					searchText,
					searchText + "%",
					searchLike,
				},
			}).Order("created_at DESC")
		} else {
			query = query.Order(clause.Expr{
				SQL: `CASE
					WHEN LOWER(nickname) = ? THEN 0
				WHEN LOWER(nickname) LIKE ? ESCAPE '\\' THEN 1
				WHEN LOWER(nickname) LIKE ? ESCAPE '\\' THEN 2
					ELSE 3
				END`,
				Vars: []interface{}{
					searchText,
					searchText + "%",
					searchLike,
				},
			}).Order("created_at DESC")
		}
	}

	var total int64
	if err := query.Count(&total).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "搜索用户失败"})
		return
	}

	var users []models.User
	if err := query.
		Select("id", "nickname", "avatar", "background", "exp", "credit_score",
			"followers_count", "following_count", "total_likes_received").
		Offset((page - 1) * limit).
		Limit(limit).
		Find(&users).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "搜索用户失败"})
		return
	}

	items := make([]PublicUserResponse, 0, len(users))
	for _, user := range users {
		items = append(items, publicUserResponse(user))
	}
	c.JSON(http.StatusOK, gin.H{
		"items": items,
		"total": total,
		"page":  page,
		"limit": limit,
	})
}

func escapeSearchLikePattern(value string) string {
	value = strings.ReplaceAll(value, `\`, `\`+`\`)
	value = strings.ReplaceAll(value, "%", `\%`)
	value = strings.ReplaceAll(value, "_", `\_`)
	return value
}

func onlySearchWildcards(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" {
		return true
	}
	for _, r := range value {
		if r != '%' && r != '_' && r != '*' && r != '?' && r != '\\' {
			return false
		}
	}
	return true
}

func (h *SearchHandler) allowAnonymousSearch(source string, now time.Time) bool {
	h.searchMu.Lock()
	defer h.searchMu.Unlock()
	cutoff := now.Add(-time.Minute)
	recent := h.searchHits[source][:0]
	for _, hit := range h.searchHits[source] {
		if hit.After(cutoff) {
			recent = append(recent, hit)
		}
	}
	if len(recent) >= 30 {
		h.searchHits[source] = recent
		return false
	}
	h.searchHits[source] = append(recent, now)
	return true
}
