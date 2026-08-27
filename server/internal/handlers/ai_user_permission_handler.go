package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5/pgconn"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// AIUserPermissionHandler 提供校园 Agent 个人数据权限的查看和更新接口。
// 路由只接受当前 JWT 用户，禁止客户端传入 user_id。
type AIUserPermissionHandler struct {
	service *services.AIUserPermissionService
}

func NewAIUserPermissionHandler(service *services.AIUserPermissionService) *AIUserPermissionHandler {
	return &AIUserPermissionHandler{service: service}
}

func (handler *AIUserPermissionHandler) List(c *gin.Context) {
	permissions, err := handler.service.List(c.Request.Context(), c.GetUint("user_id"))
	if err != nil {
		writeAIUserPermissionError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"permissions": permissions})
}

type updateAIUserPermissionRequest struct {
	Scope  models.AIUserPermissionScope  `json:"scope"`
	Policy models.AIUserPermissionPolicy `json:"policy"`
}

func (handler *AIUserPermissionHandler) Update(c *gin.Context) {
	var request updateAIUserPermissionRequest
	if err := decodeStrictJSON(c, &request, 4<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_ai_personal_data_permission", "message": "个人数据权限参数无效"})
		return
	}
	permission, err := handler.service.Set(c.Request.Context(), c.GetUint("user_id"), request.Scope, request.Policy)
	if err != nil {
		writeAIUserPermissionError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"permission": permission})
}

type setAIUserPermissionModeRequest struct {
	Mode string `json:"mode"`
}

func (handler *AIUserPermissionHandler) GetMode(c *gin.Context) {
	mode, err := handler.service.Mode(c.Request.Context(), c.GetUint("user_id"))
	if err != nil {
		writeAIUserPermissionError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"mode": mode})
}

func (handler *AIUserPermissionHandler) SetMode(c *gin.Context) {
	var request setAIUserPermissionModeRequest
	if err := decodeStrictJSON(c, &request, 1<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_ai_personal_data_permission", "message": "Agent 权限模式无效"})
		return
	}
	if err := handler.service.SetMode(c.Request.Context(), c.GetUint("user_id"), request.Mode); err != nil {
		logAIUserPermissionModeFailure(c, request.Mode, err)
		writeAIUserPermissionError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"mode": request.Mode})
}

func logAIUserPermissionModeFailure(c *gin.Context, mode string, err error) {
	normalizedMode := strings.TrimSpace(mode)
	if normalizedMode != services.AIUserPermissionModeAsk && normalizedMode != services.AIUserPermissionModeTrusted {
		normalizedMode = "invalid"
	}
	slog.Default().Error("ai_permission_mode_update_failed",
		"request_id", middleware.EnsureRequestID(c),
		"route", "/api/ai/permissions/mode",
		"method", http.MethodPut,
		"user_hash", hashAIUserPermissionUserID(c.GetUint("user_id")),
		"mode", normalizedMode,
		"error_class", classifyAIUserPermissionError(err),
	)
}

func hashAIUserPermissionUserID(userID uint) string {
	if userID == 0 {
		return "-"
	}
	digest := sha256.Sum256([]byte("ai-permission-user:" + strconv.FormatUint(uint64(userID), 10)))
	return hex.EncodeToString(digest[:8])
}

func classifyAIUserPermissionError(err error) string {
	if errors.Is(err, services.ErrInvalidAIUserPermission) {
		return "validation"
	}
	if strings.Contains(err.Error(), "ai_user_permission_version_conflict") {
		return "conflict"
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		switch pgErr.Code {
		case "42P10":
			// PostgreSQL 无法为 ON CONFLICT 找到 (user_id, scope) 唯一仲裁索引。
			return "db_unique_index_missing"
		case "42P01", "42703", "42883":
			return "schema_mismatch"
		case "23514":
			return "db_check_constraint"
		case "23502", "23503", "23505":
			return "db_constraint"
		default:
			return "db_postgres"
		}
	}
	return "database_unavailable"
}

func writeAIUserPermissionError(c *gin.Context, err error) {
	if errors.Is(err, services.ErrInvalidAIUserPermission) {
		middleware.WriteAPIError(c, http.StatusBadRequest, "invalid_ai_personal_data_permission", "个人数据权限参数无效", nil)
		return
	}
	if classifyAIUserPermissionError(err) == "conflict" {
		middleware.WriteAPIError(c, http.StatusConflict, "ai_personal_data_permission_conflict", "权限状态正在变更，请稍后重试", nil)
		return
	}

	// 分类码用于日志和客户端诊断；不把数据库结构、约束名或 SQL 暴露给用户。
	code := "ai_personal_data_permission_unavailable"
	switch classifyAIUserPermissionError(err) {
	case "schema_mismatch":
		code = "ai_personal_data_permission_schema_mismatch"
	case "db_unique_index_missing":
		code = "ai_personal_data_permission_unique_index_missing"
	case "db_check_constraint", "db_constraint":
		code = "ai_personal_data_permission_constraint_violation"
	case "database_unavailable":
		code = "ai_personal_data_permission_database_unavailable"
	}
	middleware.WriteAPIError(c, http.StatusServiceUnavailable, code, "个人数据权限服务暂时不可用，请稍后重试", nil)
}
