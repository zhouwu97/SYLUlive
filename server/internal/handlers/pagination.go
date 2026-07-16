package handlers

import (
	"strconv"

	"github.com/gin-gonic/gin"
)

// ParsePagination 统一解析页码和每页数量，并保证 offset 永不为负数。
func ParsePagination(c *gin.Context, defaultLimit, maxLimit int) (page, limit, offset int) {
	page, err := strconv.Atoi(c.DefaultQuery("page", "1"))
	if err != nil || page < 1 {
		page = 1
	}
	limit, err = strconv.Atoi(c.DefaultQuery("limit", strconv.Itoa(defaultLimit)))
	if err != nil || limit < 1 || limit > maxLimit {
		limit = defaultLimit
	}
	offset = (page - 1) * limit
	return page, limit, offset
}
