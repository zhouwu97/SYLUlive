package handlers

import (
	"net/http"
	"strconv"
	"strings"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

type SearchHandler struct {
	db          *gorm.DB
	postHandler *PostHandler
}

func NewSearchHandler(db *gorm.DB, postHandler *PostHandler) *SearchHandler {
	return &SearchHandler{db: db, postHandler: postHandler}
}

func (h *SearchHandler) Search(c *gin.Context) {
	queryText := strings.TrimSpace(c.Query("q"))
	if queryText == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请输入搜索内容"})
		return
	}

	searchType := c.DefaultQuery("type", "posts")
	sort := c.DefaultQuery("sort", "relevance")
	page := parsePositiveInt(c.Query("page"), 1)
	limit := parsePositiveInt(c.Query("limit"), 20)
	if limit > 50 {
		limit = 50
	}

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
	searchLike := "%" + searchText + "%"
	query := h.db.Model(&models.Post{}).
		Where("status = ?", models.PostStatusNormal).
		Where("(LOWER(title) LIKE ? OR LOWER(content) LIKE ?)", searchLike, searchLike).
		Preload("Author").
		Preload("Images").
		Preload("Images.File")

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
				WHEN LOWER(title) LIKE ? THEN 1
				WHEN LOWER(title) LIKE ? THEN 2
				WHEN LOWER(content) LIKE ? THEN 3
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
	h.postHandler.fillLikes(c, posts)
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
	searchLike := "%" + searchText + "%"
	query := h.db.Model(&models.User{}).
		Where("(LOWER(student_id) LIKE ? OR LOWER(nickname) LIKE ?)", searchLike, searchLike)

	if sort == "newest" {
		query = query.Order("created_at DESC")
	} else {
		query = query.Order(clause.Expr{
			SQL: `CASE
				WHEN LOWER(student_id) = ? THEN 0
				WHEN LOWER(nickname) = ? THEN 1
				WHEN LOWER(student_id) LIKE ? THEN 2
				WHEN LOWER(nickname) LIKE ? THEN 3
				ELSE 4
			END`,
			Vars: []interface{}{
				searchText,
				searchText,
				searchText + "%",
				searchText + "%",
			},
		}).Order("created_at DESC")
	}

	var total int64
	if err := query.Count(&total).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "搜索用户失败"})
		return
	}

	var users []models.User
	if err := query.
		Select("id", "student_id", "nickname", "gender", "avatar", "background",
			"credit_score", "role", "admin_exp", "exp", "credits", "created_at",
			"edu_bound", "edu_grade", "edu_college", "edu_major",
			"followers_count", "following_count", "total_likes_received").
		Offset((page - 1) * limit).
		Limit(limit).
		Find(&users).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "搜索用户失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"items": users,
		"total": total,
		"page":  page,
		"limit": limit,
	})
}
