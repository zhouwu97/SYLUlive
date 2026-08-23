package handlers

import (
	"net/http"
	"strconv"
	"strings"

	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// TopicHandler 提供选择器所需的轻量搜索与推荐接口。
type TopicHandler struct{ db *gorm.DB }

func NewTopicHandler(db *gorm.DB) *TopicHandler { return &TopicHandler{db: db} }

func (h *TopicHandler) Search(c *gin.Context) {
	limit := parseTopicLimit(c.Query("limit"))
	topics, err := services.SearchTopics(h.db, c.Query("q"), c.Query("section"), limit)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "搜索话题失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"topics": topics})
}

func (h *TopicHandler) Recommend(c *gin.Context) {
	limit := parseTopicLimit(c.Query("limit"))
	topics, err := services.SearchTopics(h.db, c.Query("q"), c.Query("section"), limit)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取话题推荐失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"topics": topics})
}

func parseTopicLimit(raw string) int {
	limit, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || limit <= 0 {
		return 20
	}
	if limit > 50 {
		return 50
	}
	return limit
}
