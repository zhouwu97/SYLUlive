package handlers

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// defaultCheckAfterSeconds 是服务端建议客户端下次再检查的最小间隔。
// 客户端在收到 200 响应后可以按这个值回填本地缓存策略，避免每次冷启动都
// 直接打服务端。6 小时为常用 APK 更新的发布窗口节奏。
const defaultCheckAfterSeconds = 21600

// AppUpdateHandler 处理公开的应用更新检查与 APK 下载接口。
//
// 阶段 A 只暴露 CheckUpdate；Download、HEAD 等子路由在阶段 A5-A6 加入，
// 二者共用同一个 Handler 结构以便后续阶段在前面加统一的日志或限流中间件。
type AppUpdateHandler struct {
	svc *services.AppReleaseService
}

// NewAppUpdateHandler 构造 AppUpdateHandler。
func NewAppUpdateHandler(svc *services.AppReleaseService) *AppUpdateHandler {
	return &AppUpdateHandler{svc: svc}
}

// updateCheckResponse 是给客户端的统一响应。无更新时 file 等字段为空，
// 客户端必须能容忍这一情况。
type updateCheckResponse struct {
	UpdateAvailable              bool   `json:"update_available"`
	UpdateType                   string `json:"update_type"`
	CurrentVersionName           string `json:"current_version_name,omitempty"`
	CurrentVersionCode           int64  `json:"current_version_code,omitempty"`
	LatestVersionName            string `json:"latest_version_name"`
	LatestVersionCode            int64  `json:"latest_version_code"`
	MinimumSupportedVersionCode int64  `json:"minimum_supported_version_code"`
	Title                        string `json:"title,omitempty"`
	Changelog                    string `json:"changelog,omitempty"`
	FileSize                     int64  `json:"file_size,omitempty"`
	SHA256                       string `json:"sha256,omitempty"`
	DownloadURL                  string `json:"download_url,omitempty"`
	PublishedAt                  string `json:"published_at,omitempty"`
	CheckAfterSeconds            int    `json:"check_after_seconds"`
}

// CheckUpdate 处理 GET /api/app/update。
//
// 不需要登录。Query 优先于请求头，相同字段任一来源为空时回退到另一个来源。
// 没有已发布版本时返回 200 + update_available=false，避免 App 启动失败。
func (h *AppUpdateHandler) CheckUpdate(c *gin.Context) {
	platform := firstNonEmpty(c.Query("platform"), c.GetHeader("X-App-Platform"))
	channel := firstNonEmpty(c.Query("channel"), c.GetHeader("X-App-Channel"))
	versionName := firstNonEmpty(c.Query("version_name"), c.GetHeader("X-App-Version-Name"))
	versionCodeRaw := firstNonEmpty(c.Query("version_code"), c.GetHeader("X-App-Version-Code"))

	// 首版只接受 android/stable。其他平台按"不支持"返回 400，避免客户端误读
	// 强制状态。
	if platform != models.AppReleasePlatformAndroid {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "unsupported platform",
			"code":  "unsupported_platform",
		})
		return
	}
	if channel != models.AppReleaseChannelStable {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "unsupported channel",
			"code":  "unsupported_channel",
		})
		return
	}
	if versionCodeRaw == "" {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "version_code is required",
			"code":  "missing_version_code",
		})
		return
	}
	currentVersionCode, err := strconv.ParseInt(versionCodeRaw, 10, 64)
	if err != nil || currentVersionCode <= 0 {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "invalid version_code",
			"code":  "invalid_version_code",
		})
		return
	}
	if versionName == "" {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "version_name is required",
			"code":  "missing_version_name",
		})
		return
	}

	ctx, cancel := context.WithTimeout(c.Request.Context(), 5*time.Second)
	defer cancel()

	latest, err := h.svc.GetLatestPublished(ctx, platform, channel)
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			// 任何"尚未发布版本"的情况一律放行，避免 App 启动失败。客户端
			// 看到响应后应按 check_after_seconds 等再检查。
			c.JSON(http.StatusOK, updateCheckResponse{
				UpdateAvailable:              false,
				UpdateType:                   string(services.UpdateNone),
				CurrentVersionName:           versionName,
				CurrentVersionCode:           currentVersionCode,
				LatestVersionName:            versionName,
				LatestVersionCode:            currentVersionCode,
				MinimumSupportedVersionCode:  0,
				CheckAfterSeconds:            defaultCheckAfterSeconds,
			})
			return
		}
		// 数据库异常属于服务端错误，不伪装成"无更新"。
		c.JSON(http.StatusServiceUnavailable, gin.H{
			"error": "update service temporarily unavailable",
			"code":  "update_check_unavailable",
		})
		return
	}

	decision := services.DecideUpdate(currentVersionCode, latest.VersionCode, latest.MinimumSupportedVersionCode)

	// 构造统一响应：无更新时 file/title/changelog 为空，让客户端直接进入 App。
	resp := updateCheckResponse{
		UpdateAvailable:              decision != services.UpdateNone,
		UpdateType:                   string(decision),
		CurrentVersionName:           versionName,
		CurrentVersionCode:           currentVersionCode,
		LatestVersionName:            latest.VersionName,
		LatestVersionCode:            latest.VersionCode,
		MinimumSupportedVersionCode:  latest.MinimumSupportedVersionCode,
		CheckAfterSeconds:            defaultCheckAfterSeconds,
	}
	if decision != services.UpdateNone {
		resp.Title = latest.Title
		resp.Changelog = latest.Changelog
		resp.FileSize = latest.FileSize
		resp.SHA256 = latest.SHA256
		resp.DownloadURL = formatAPKDownloadURL(latest.ID)
		if latest.PublishedAt != nil {
			resp.PublishedAt = latest.PublishedAt.UTC().Format(time.RFC3339)
		}
	}
	c.JSON(http.StatusOK, resp)
}

// formatAPKDownloadURL 生成相对路径，让客户端自己拼绝对 URL。
// 用 %d 而不是字符串拼接，避免任何来自 latest.ID 的 fmt.Xxx 注入风险。
// SQL 自增主键 ID 都是非负整数，无需额外清理。
func formatAPKDownloadURL(id uint) string {
	// strconv.FormatUint 避免变成 fmt.Sprintf 调用栈。
	return "/api/app/releases/" + strconv.FormatUint(uint64(id), 10) + "/download"
}

// firstNonEmpty 返回第一个非空字符串（去除前后空白后判定）。
// 既用于 query 也用于 header fallback。
func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if trimmed := strings.TrimSpace(v); trimmed != "" {
			return trimmed
		}
	}
	return ""
}