package handlers

import (
	"errors"
	"net/http"
	"strconv"

	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// TeacherGovernanceHandler 教师与课程数据治理 HTTP 层。
// 只负责参数解析、权限取值、错误码映射，业务规则由 TeacherGovernanceService 承载。
type TeacherGovernanceHandler struct {
	service *services.TeacherGovernanceService
}

func NewTeacherGovernanceHandler(db *gorm.DB) *TeacherGovernanceHandler {
	return &TeacherGovernanceHandler{service: services.NewTeacherGovernanceService(db)}
}

// respondGovernanceError 把治理业务错误统一映射为稳定业务码。
func respondGovernanceError(c *gin.Context, err error) {
	var businessErr *services.TeacherGovernanceError
	if errors.As(err, &businessErr) {
		response := gin.H{
			"error": businessErr.Message,
			"code":  businessErr.Code,
		}
		for key, value := range businessErr.Details {
			response[key] = value
		}
		c.JSON(services.TeacherGovernanceHTTPStatus(businessErr.Code), response)
		return
	}
	c.JSON(http.StatusInternalServerError, gin.H{
		"error": "教师治理服务异常，请稍后重试",
		"code":  services.CodeTeacherGovernanceInternalError,
	})
}

// governanceAdminID 取出中间件写入的管理员用户 ID。
func governanceAdminID(c *gin.Context) uint {
	if value, exists := c.Get("user_id"); exists {
		switch uid := value.(type) {
		case uint:
			return uid
		case int:
			if uid > 0 {
				return uint(uid)
			}
		case int64:
			if uid > 0 {
				return uint(uid)
			}
		case float64:
			if uid > 0 {
				return uint(uid)
			}
		}
	}
	return 0
}

// ListDuplicateGroups 返回疑似重复教师分组。
func (h *TeacherGovernanceHandler) ListDuplicateGroups(c *gin.Context) {
	groups, err := h.service.ListDuplicateGroups()
	if err != nil {
		respondGovernanceError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"groups": groups})
}

// PreviewMerge 干跑一次合并，返回影响预览。
func (h *TeacherGovernanceHandler) PreviewMerge(c *gin.Context) {
	var input services.MergeInput
	if err := c.ShouldBindJSON(&input); err != nil {
		respondGovernanceError(c, &services.TeacherGovernanceError{
			Code:    services.CodeTeacherGovernanceInvalidInput,
			Message: "请求体格式错误",
			Err:     err,
		})
		return
	}
	plan, err := h.service.PreviewMerge(input)
	if err != nil {
		respondGovernanceError(c, err)
		return
	}
	c.JSON(http.StatusOK, plan)
}

// Merge 执行教师合并。
func (h *TeacherGovernanceHandler) Merge(c *gin.Context) {
	adminID := governanceAdminID(c)
	if adminID == 0 {
		respondGovernanceError(c, &services.TeacherGovernanceError{
			Code:    services.CodeTeacherGovernanceForbidden,
			Message: "无权执行教师合并",
		})
		return
	}
	var input services.MergeInput
	if err := c.ShouldBindJSON(&input); err != nil {
		respondGovernanceError(c, &services.TeacherGovernanceError{
			Code:    services.CodeTeacherGovernanceInvalidInput,
			Message: "请求体格式错误",
			Err:     err,
		})
		return
	}
	plan, err := h.service.Merge(adminID, input)
	if err != nil {
		respondGovernanceError(c, err)
		return
	}
	c.JSON(http.StatusOK, plan)
}

// ListTeachers 治理页"全部教师"列表。
func (h *TeacherGovernanceHandler) ListTeachers(c *gin.Context) {
	limit := 0
	if raw := c.Query("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil {
			limit = parsed
		}
	}
	teachers, err := h.service.ListGovernanceTeachers(c.Query("q"), limit)
	if err != nil {
		respondGovernanceError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": teachers})
}

// ListAliases 读取课程/教师别名。
func (h *TeacherGovernanceHandler) ListAliases(c *gin.Context) {
	aliases, err := h.service.ListAliases(c.Query("type"))
	if err != nil {
		respondGovernanceError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": aliases})
}

// AddAlias 手动登记课程/教师别名。
func (h *TeacherGovernanceHandler) AddAlias(c *gin.Context) {
	adminID := governanceAdminID(c)
	if adminID == 0 {
		respondGovernanceError(c, &services.TeacherGovernanceError{
			Code:    services.CodeTeacherGovernanceForbidden,
			Message: "无权管理别名",
		})
		return
	}
	var input services.AddAliasInput
	if err := c.ShouldBindJSON(&input); err != nil {
		respondGovernanceError(c, &services.TeacherGovernanceError{
			Code:    services.CodeTeacherGovernanceInvalidInput,
			Message: "请求体格式错误",
			Err:     err,
		})
		return
	}
	view, err := h.service.AddAlias(adminID, input)
	if err != nil {
		respondGovernanceError(c, err)
		return
	}
	c.JSON(http.StatusOK, view)
}

// DeleteAlias 删除一条别名。
func (h *TeacherGovernanceHandler) DeleteAlias(c *gin.Context) {
	adminID := governanceAdminID(c)
	if adminID == 0 {
		respondGovernanceError(c, &services.TeacherGovernanceError{
			Code:    services.CodeTeacherGovernanceForbidden,
			Message: "无权管理别名",
		})
		return
	}
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || id == 0 {
		respondGovernanceError(c, &services.TeacherGovernanceError{
			Code:    services.CodeTeacherGovernanceInvalidInput,
			Message: "无效的别名 ID",
		})
		return
	}
	if err := h.service.DeleteAlias(adminID, c.Param("type"), uint(id)); err != nil {
		respondGovernanceError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已删除"})
}

// ListMergeRecords 读取处理记录。
func (h *TeacherGovernanceHandler) ListMergeRecords(c *gin.Context) {
	limit := 0
	if raw := c.Query("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil {
			limit = parsed
		}
	}
	records, err := h.service.ListMergeRecords(limit)
	if err != nil {
		respondGovernanceError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": records})
}
