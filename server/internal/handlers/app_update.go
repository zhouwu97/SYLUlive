package handlers

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
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

// apkContentType 是 Android 安装包的标准 MIME，避免依赖 Gin 的内容协商。
const apkContentType = "application/vnd.android.package-archive"

// AppUpdateHandler 处理公开的应用更新检查与 APK 下载接口。
//
// Download 支持 http.ServeContent 默认实现（处理 Range / 206 / If-Range /
// Last-Modified）以及 Nginx X-Accel-Redirect 模式。X-Accel 模式通过独立开关
// 启用，开关默认 false；只有当服务器明确配置了 Nginx 内部 location 后才应
// 切到 true。
type AppUpdateHandler struct {
	svc              *services.AppReleaseService
	useAccelRedirect bool
	accelPrefix      string
}

// NewAppUpdateHandler 构造 AppUpdateHandler。
//
//	useAccelRedirect: 来自 cfg.AppReleaseUseAccelRedirect
//	accelPrefix:      来自 cfg.AppReleaseAccelPrefix，例如 "/_internal/app-releases/"
func NewAppUpdateHandler(svc *services.AppReleaseService, useAccelRedirect bool, accelPrefix string) *AppUpdateHandler {
	prefix := strings.TrimSpace(accelPrefix)
	if prefix == "" {
		prefix = "/_internal/app-releases/"
	}
	if !strings.HasPrefix(prefix, "/") {
		prefix = "/" + prefix
	}
	if !strings.HasSuffix(prefix, "/") {
		prefix = prefix + "/"
	}
	return &AppUpdateHandler{
		svc:              svc,
		useAccelRedirect: useAccelRedirect,
		accelPrefix:      prefix,
	}
}

// updateCheckResponse 是给客户端的统一响应。无更新时 file 等字段为空，
// 客户端必须能容忍这一情况。
type updateCheckResponse struct {
	UpdateAvailable             bool   `json:"update_available"`
	UpdateType                  string `json:"update_type"`
	CurrentVersionName          string `json:"current_version_name,omitempty"`
	CurrentVersionCode          int64  `json:"current_version_code,omitempty"`
	LatestVersionName           string `json:"latest_version_name"`
	LatestVersionCode           int64  `json:"latest_version_code"`
	MinimumSupportedVersionCode int64  `json:"minimum_supported_version_code"`
	Title                       string `json:"title,omitempty"`
	Changelog                   string `json:"changelog,omitempty"`
	FileSize                    int64  `json:"file_size,omitempty"`
	SHA256                      string `json:"sha256,omitempty"`
	DownloadURL                 string `json:"download_url,omitempty"`
	PublishedAt                 string `json:"published_at,omitempty"`
	CheckAfterSeconds           int    `json:"check_after_seconds"`
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

	// 鸿蒙已具备独立的 HAP 构建链路；尚未发布鸿蒙版本时按无更新放行，
	// 不能因为更新检查本身阻断首次启动。
	if platform != models.AppReleasePlatformAndroid && platform != models.AppReleasePlatformOhos {
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
				UpdateAvailable:             false,
				UpdateType:                  string(services.UpdateNone),
				CurrentVersionName:          versionName,
				CurrentVersionCode:          currentVersionCode,
				LatestVersionName:           versionName,
				LatestVersionCode:           currentVersionCode,
				MinimumSupportedVersionCode: 0,
				CheckAfterSeconds:           defaultCheckAfterSeconds,
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
		UpdateAvailable:             decision != services.UpdateNone,
		UpdateType:                  string(decision),
		CurrentVersionName:          versionName,
		CurrentVersionCode:          currentVersionCode,
		LatestVersionName:           latest.VersionName,
		LatestVersionCode:           latest.VersionCode,
		MinimumSupportedVersionCode: latest.MinimumSupportedVersionCode,
		CheckAfterSeconds:           defaultCheckAfterSeconds,
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

// Download 处理 GET/HEAD /api/app/releases/:id/download。
//
// 仅允许 published 状态的 release 被下载；withdrawn 一律拒绝新下载。dev 模式
// 默认通过 http.ServeContent 推送字节流并自动支持 Range / 206 / ETag。
// prod 模式启用 APP_RELEASE_USE_ACCEL_REDIRECT=true 时改返回 X-Accel-Redirect，
// 让 Nginx 通过 internal location 投递大文件，Go 进程不必持有句柄太久。
//
// “客户端永远不应该决定可信状态”：所有路径来自 DB 的受控 StorageKey，
// 并通过 services.LocateAPK 拒绝穿越，然后再做磁盘存在与大小校验。
func (h *AppUpdateHandler) Download(c *gin.Context) {
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil || id == 0 {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "invalid release id",
			"code":  "invalid_release_id",
		})
		return
	}

	var release models.AppRelease
	if err := h.svc.DB().First(&release, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{
				"error": "release not found",
				"code":  "release_not_found",
			})
			return
		}
		c.JSON(http.StatusServiceUnavailable, gin.H{
			"error": "release lookup failed",
			"code":  "release_lookup_failed",
		})
		return
	}
	if release.Status != models.AppReleaseStatusPublished {
		c.JSON(http.StatusNotFound, gin.H{
			"error": "release not available for download",
			"code":  "release_not_downloadable",
		})
		return
	}

	apkPath, err := h.svc.LocateAPK(&release)
	if err != nil {
		// 路径穿越属于服务端配置错误或数据破坏，不把细节回给客户端。
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "release storage misconfigured",
			"code":  "storage_misconfigured",
		})
		return
	}
	info, err := os.Stat(apkPath)
	if err != nil {
		// 文件不在磁盘上但 DB 状态是 published —— 视为 404，让客户端重新
		// /api/app/update 拉取策略。
		c.JSON(http.StatusNotFound, gin.H{
			"error": "release file missing",
			"code":  "release_file_missing",
		})
		return
	}
	if info.IsDir() {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "release storage misconfigured",
			"code":  "storage_misconfigured",
		})
		return
	}
	if release.FileSize > 0 && info.Size() != release.FileSize {
		// 与数据库记录的预期大小不符 —— 不要给客户端可能损坏的包。
		c.JSON(http.StatusServiceUnavailable, gin.H{
			"error": "release file size mismatch",
			"code":  "release_size_mismatch",
		})
		return
	}

	// 文件名：客户端习惯看到 .apk 扩展，且应取 DB 中的 FileName 而不是磁盘
	// 文件名，避免泄露内部存储结构。
	filename := strings.TrimSpace(release.FileName)
	if filename == "" {
		filename = "release-" + strconv.FormatUint(id, 10) + ".apk"
	}

	// 主体安全/缓存头。
	c.Header("Content-Type", apkContentType)
	c.Header("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, sanitizeDispositionFilename(filename)))
	c.Header("X-Content-Type-Options", "nosniff")
	c.Header("Cache-Control", "public, max-age=86400, immutable")
	c.Header("ETag", `"`+release.SHA256+`"`)

	if release.PublishedAt != nil {
		c.Header("Last-Modified", release.PublishedAt.UTC().Format(http.TimeFormat))
	}

	if h.useAccelRedirect {
		// X-Accel-Redirect：让 Nginx 通过 internal location 投递文件。Nginx
		// 反代需要把 accelPrefix 的 alias 指向 cfg.AppReleaseDir。
		// 路径用 filepath.ToSlash 还原为 UNIX 风格，Nginx 期望正斜杠。
		relative := strings.TrimPrefix(filepath.ToSlash(apkPath), filepath.ToSlash(h.svc.ReleaseDir()))
		relative = strings.TrimPrefix(relative, "/")
		c.Header("X-Accel-Redirect", h.accelPrefix+relative)
		c.Status(http.StatusOK)
		return
	}

	// 默认分支：让 Go 自己读文件。http.ServeContent 自动处理 HEAD、Range、
	// 206、If-Range、If-Modified-Since。我们已显式写了 ETag / Last-Modified
	// 会让部分客户端受益，ServeContent 不会重写它们。
	f, err := os.Open(apkPath)
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{
			"error": "release file unreadable",
			"code":  "release_file_unreadable",
		})
		return
	}
	defer f.Close()
	http.ServeContent(c.Writer, c.Request, apkContentType, info.ModTime(), f)
}

// sanitizeDispositionFilename 把文件名中可能破坏 Content-Disposition 解析
// 的字符替换成下划线。release.FileName 来自数据库，按计划只允许普通文件名，
// 但再加一层防御不会让客户端更脆弱。
func sanitizeDispositionFilename(name string) string {
	// 去掉任何路径分隔符与控制字符，避免 Content-Disposition 注入。
	name = strings.ReplaceAll(name, "\\", "_")
	name = strings.ReplaceAll(name, "\"", "_")
	name = strings.ReplaceAll(name, "\r", "_")
	name = strings.ReplaceAll(name, "\n", "_")
	// 限制长度，避免 header 超长。
	if len(name) > 120 {
		name = name[:120]
	}
	return name
}
