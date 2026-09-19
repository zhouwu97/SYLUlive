package handlers

import (
	"errors"
	"math"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
)

// ParsePagination 统一解析页码和每页数量，并保证 offset 永不为负数。
//
// 该函数保留既有“宽容”语义（非法值静默回退到默认值），仅用于维持旧调用方行为。
// 本轮变更的列表入口请使用 ParsePaginationStrict，避免非法参数被静默当成 0/1 后
// 继续进入切片与 SQL 分页。
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
	if offset < 0 {
		// page 极大时 (page-1)*limit 可能溢出为负数；兜底保证不产生负偏移。
		page = 1
		offset = 0
	}
	return page, limit, offset
}

// 分页参数错误，调用方统一映射为 400。
var (
	// ErrInvalidPage 表示显式传入的 page 非法。
	ErrInvalidPage = errors.New("invalid_page")
	// ErrInvalidLimit 表示显式传入的 limit 非法。
	ErrInvalidLimit = errors.New("invalid_limit")
	// ErrInvalidOffset 表示显式传入的 offset 非法。
	ErrInvalidOffset = errors.New("invalid_offset")
)

// parsePositiveIntQuery 解析显式传入的正整数查询参数。
// 未传（或仅空白）时返回 def 与 provided=false；传入但非数字、超出 int 表示范围
// 或小于 min 时返回错误，避免被静默当成 0 继续参与运算。
func parsePositiveIntQuery(c *gin.Context, key string, def, min int) (value int, provided bool, err error) {
	raw := strings.TrimSpace(c.Query(key))
	if raw == "" {
		return def, false, nil
	}
	parsed, convErr := strconv.Atoi(raw)
	if convErr != nil || parsed < min {
		return 0, true, errors.New("invalid_value")
	}
	return parsed, true, nil
}

// ParsePaginationStrict 解析 page/limit 并计算 offset，非法显式参数直接返回错误。
//
// 规则：
//   - 未传 page → 1；未传 limit → defaultLimit。
//   - 显式 page 必须为正，显式 limit 必须为正；显式 0 与缺省值语义不同，属于非法值。
//   - 非数字、超出 int 表示范围的输入返回错误，而不是退化为 0 后继续分页。
//   - limit 超过 maxLimit 时按 maxLimit 截断：既保证不取超大页，也保持对旧客户端
//     “传大值”的容忍，不因为一个上限就拒绝整条请求。
//   - (page-1)*limit 做溢出检查，避免负数 offset 进入切片。
func ParsePaginationStrict(c *gin.Context, defaultLimit, maxLimit int) (page, limit, offset int, err error) {
	page, _, err = parsePositiveIntQuery(c, "page", 1, 1)
	if err != nil {
		return 0, 0, 0, ErrInvalidPage
	}
	limit, limitProvided, err := parsePositiveIntQuery(c, "limit", defaultLimit, 1)
	if err != nil {
		return 0, 0, 0, ErrInvalidLimit
	}
	if limitProvided && limit > maxLimit {
		limit = maxLimit
	}
	if limit <= 0 {
		limit = defaultLimit
	}
	if page > math.MaxInt32 && limit > 1 {
		return 0, 0, 0, ErrInvalidPage
	}
	offset = (page - 1) * limit
	if offset < 0 {
		return 0, 0, 0, ErrInvalidPage
	}
	return page, limit, offset, nil
}

// ParseOffsetStrict 解析显式 offset 查询参数。
// 未传时返回 fallback 且 provided=false；传入时必须是 0 或正整数，否则返回错误。
func ParseOffsetStrict(c *gin.Context, fallback int) (offset int, provided bool, err error) {
	raw := strings.TrimSpace(c.Query("offset"))
	if raw == "" {
		return fallback, false, nil
	}
	value, convErr := strconv.Atoi(raw)
	if convErr != nil || value < 0 {
		return 0, true, ErrInvalidOffset
	}
	return value, true, nil
}
