package middleware

import (
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

const (
	appVersionPlatformHeader = "X-App-Platform"
	appVersionChannelHeader  = "X-App-Channel"
	appVersionNameHeader     = "X-App-Version-Name"
	appVersionCodeHeader     = "X-App-Version-Code"
)

// AppVersionMiddleware 对低于当前最低支持构建号的 App 业务请求返回 426。
// 更新检查、APK 下载、健康检查及登录迁移接口必须保持可用，否则旧客户端
// 会被锁定在无法获取新安装包的状态。启用前应先发布携带版本请求头的桥接版本。
func AppVersionMiddleware(db *gorm.DB, enabled, allowMissingVersionHeaders bool) gin.HandlerFunc {
	return func(c *gin.Context) {
		if !enabled || !strings.HasPrefix(c.Request.URL.Path, "/api/") || isAppVersionExempt(c.Request.URL.Path) {
			c.Next()
			return
		}

		platform := strings.TrimSpace(c.GetHeader(appVersionPlatformHeader))
		channel := strings.TrimSpace(c.GetHeader(appVersionChannelHeader))
		versionName := strings.TrimSpace(c.GetHeader(appVersionNameHeader))
		versionCodeRaw := strings.TrimSpace(c.GetHeader(appVersionCodeHeader))
		if platform == "" || channel == "" || versionName == "" || versionCodeRaw == "" {
			if allowMissingVersionHeaders {
				log.Printf("[APP_VERSION] 放行缺少版本头的请求 method=%s path=%s", c.Request.Method, c.Request.URL.Path)
				c.Next()
				return
			}
			writeAppUpdateRequired(c, nil)
			return
		}

		// 首版仅发布 Android stable 包。非移动端标识不参与 APK 策略，避免
		// 将未来平台或管理脚本误判为 Android 旧客户端。
		if platform != models.AppReleasePlatformAndroid || channel != models.AppReleaseChannelStable {
			c.Next()
			return
		}

		currentVersionCode, err := strconv.ParseInt(versionCodeRaw, 10, 64)
		if err != nil || currentVersionCode <= 0 {
			writeAppUpdateRequired(c, nil)
			return
		}

		var latest models.AppRelease
		err = db.Where("platform = ? AND channel = ? AND status = ?", platform, channel, models.AppReleaseStatusPublished).
			Order("version_code DESC, id DESC").First(&latest).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			// 尚未发布 APK 时不拦截，避免配置提前开启造成全量不可用。
			c.Next()
			return
		}
		if err != nil {
			log.Printf("[APP_VERSION] 读取发布版本失败: %v", err)
			c.JSON(http.StatusServiceUnavailable, gin.H{
				"code":    "APP_UPDATE_CHECK_UNAVAILABLE",
				"message": "版本策略暂不可用，请稍后重试",
			})
			c.Abort()
			return
		}

		if currentVersionCode >= latest.MinimumSupportedVersionCode {
			c.Next()
			return
		}

		writeAppUpdateRequired(c, &latest)
	}
}

// isAppVersionExempt 返回在强制更新期间仍必须能访问的接口。
func isAppVersionExempt(path string) bool {
	if path == "/health" || path == "/api/app/update" {
		return true
	}
	if strings.HasPrefix(path, "/api/app/releases/") && strings.HasSuffix(path, "/download") {
		return true
	}

	// 迁移期的匿名认证入口：旧客户端需要先完成登录或找回账号，再获取更新策略。
	switch path {
	case "/api/login", "/api/login_edu", "/api/send_code", "/api/verify_code", "/api/register", "/api/forgot_password":
		return true
	default:
		return false
	}
}

// writeAppUpdateRequired 统一返回客户端可直接消费的 426 协议。未拿到发布记录
// 时仍返回明确的强制更新码，客户端会主动访问 /api/app/update 重拉完整策略。
func writeAppUpdateRequired(c *gin.Context, latest *models.AppRelease) {
	update := gin.H{"update_type": "required"}
	if latest != nil {
		update["latest_version_name"] = latest.VersionName
		update["latest_version_code"] = latest.VersionCode
		update["minimum_supported_version_code"] = latest.MinimumSupportedVersionCode
		update["download_url"] = "/api/app/releases/" + strconv.FormatUint(uint64(latest.ID), 10) + "/download"
		update["sha256"] = latest.SHA256
		update["file_size"] = latest.FileSize
	}
	c.JSON(http.StatusUpgradeRequired, gin.H{
		"code":    "APP_UPDATE_REQUIRED",
		"message": "当前版本已停止服务，请更新后继续使用",
		"update":  update,
	})
	c.Abort()
}
