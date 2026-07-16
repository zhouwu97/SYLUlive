package handlers

import (
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestParsePaginationClampsInvalidValues(t *testing.T) {
	gin.SetMode(gin.TestMode)
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest("GET", "/?page=-2&limit=999", nil)
	page, limit, offset := ParsePagination(c, 20, 50)
	if page != 1 || limit != 20 || offset != 0 {
		t.Fatalf("分页归一化错误: page=%d limit=%d offset=%d", page, limit, offset)
	}
}
