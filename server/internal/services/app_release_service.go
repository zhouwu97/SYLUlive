package services

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// UpdateDecision 是服务端对客户端版本检查结果的最终判定。
//
// 客户端永远不应该自行决定强制状态；强制的唯一来源是服务端响应里的
// update_type 字段，其值由这里的 DecideUpdate 推导。
type UpdateDecision string

const (
	// UpdateNone 表示客户端已是最新或更新版本，不需要任何动作。
	UpdateNone UpdateDecision = "none"
	// UpdateOptional 表示客户端版本低于最新但高于最低支持版本，可延迟升级。
	UpdateOptional UpdateDecision = "optional"
	// UpdateRequired 表示客户端版本低于最低支持版本，必须升级才能继续使用。
	UpdateRequired UpdateDecision = "required"
)

// AppReleaseService 负责读取最新发布版本并推导更新决策；它不负责 APK 文件
// 写入和管理员操作（那是后续阶段的发布接口的职责）。
type AppReleaseService struct {
	db                         *gorm.DB
	releaseDir                 string
	maxSize                    int64
	androidPackageName         string
	androidSigningCertificate  string
	androidAAPT2Path           string
	androidAPKSignerPath       string
	externalMarketAllowedHosts []string
}

// NewAppReleaseService 构造一个 AppReleaseService。releaseDir 是配置中的
// APP_RELEASE_DIR，唯一用途是 LocateAPK 的路径解析。
func NewAppReleaseService(db *gorm.DB, releaseDir string, maxSizes ...int64) *AppReleaseService {
	maxSize := defaultAppReleaseMaxSize
	if len(maxSizes) > 0 && maxSizes[0] > 0 {
		maxSize = maxSizes[0]
	}
	return &AppReleaseService{db: db, releaseDir: releaseDir, maxSize: maxSize}
}

// SetAndroidAPKValidationPolicy 启用包名、版本和签名证书的发布校验。
// 未配置策略时保留开发/单元测试的 ZIP fixture 兼容性；生产启动由 main 注入完整策略。
func (s *AppReleaseService) SetAndroidAPKValidationPolicy(packageName, certificate, aapt2Path, apksignerPath string) {
	s.androidPackageName = strings.TrimSpace(packageName)
	s.androidSigningCertificate = strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(certificate), ":", ""))
	s.androidAAPT2Path = strings.TrimSpace(aapt2Path)
	s.androidAPKSignerPath = strings.TrimSpace(apksignerPath)
}

// SetExternalMarketAllowlist 设置外部市场跳转域名白名单。
func (s *AppReleaseService) SetExternalMarketAllowlist(hosts []string) {
	s.externalMarketAllowedHosts = append([]string(nil), hosts...)
}

func (s *AppReleaseService) validateExternalMarketURL(actionURL string) error {
	parsedURL, err := url.ParseRequestURI(actionURL)
	if err != nil || parsedURL.Scheme != "https" || parsedURL.Host == "" || parsedURL.User != nil || parsedURL.Port() != "" {
		return fmt.Errorf("%w: 外部市场 action_url 必须是 HTTPS 且不能包含用户信息或端口", ErrAppReleaseInvalid)
	}
	if len(s.externalMarketAllowedHosts) == 0 {
		return nil
	}
	host := strings.ToLower(strings.TrimSuffix(parsedURL.Hostname(), "."))
	for _, allowed := range s.externalMarketAllowedHosts {
		if host == strings.ToLower(strings.TrimSuffix(strings.TrimSpace(allowed), ".")) {
			return nil
		}
	}
	return fmt.Errorf("%w: 外部市场域名不在白名单内", ErrAppReleaseInvalid)
}

func (s *AppReleaseService) validateAndroidAPK(ctx context.Context, path, versionName string, versionCode int64) error {
	if s.androidPackageName == "" && s.androidSigningCertificate == "" && s.androidAAPT2Path == "" && s.androidAPKSignerPath == "" {
		return nil
	}
	if s.androidPackageName == "" || s.androidSigningCertificate == "" || s.androidAAPT2Path == "" || s.androidAPKSignerPath == "" {
		return fmt.Errorf("%w: APK 发布校验策略未完整配置", ErrAppReleaseInvalid)
	}

	badgingOutput, err := exec.CommandContext(ctx, s.androidAAPT2Path, "dump", "badging", path).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: APK 包信息校验失败", ErrAppReleaseInvalid)
	}
	packageMatch := regexp.MustCompile(`package: name='([^']+)' versionCode='([^']+)' versionName='([^']*)'`).FindStringSubmatch(string(badgingOutput))
	if len(packageMatch) != 4 || packageMatch[1] != s.androidPackageName || packageMatch[2] != strconv.FormatInt(versionCode, 10) || packageMatch[3] != versionName {
		return fmt.Errorf("%w: APK 包名或版本与发布记录不一致", ErrAppReleaseInvalid)
	}

	if output, err := exec.CommandContext(ctx, s.androidAPKSignerPath, "verify", "--verbose", path).CombinedOutput(); err != nil {
		_ = output
		return fmt.Errorf("%w: APK 签名校验失败", ErrAppReleaseInvalid)
	}
	certOutput, err := exec.CommandContext(ctx, s.androidAPKSignerPath, "verify", "--print-certs", path).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: APK 签名证书读取失败", ErrAppReleaseInvalid)
	}
	digests := regexp.MustCompile(`(?im)certificate SHA-256 digest:\s*([0-9a-f:]+)`).FindAllStringSubmatch(string(certOutput), -1)
	if len(digests) != 1 || strings.ToUpper(strings.ReplaceAll(digests[0][1], ":", "")) != s.androidSigningCertificate {
		return fmt.Errorf("%w: APK 签名证书不匹配", ErrAppReleaseInvalid)
	}
	return nil
}

// DB 暴露内部 *gorm.DB 给同包 handler 使用，避免重复构造和散落的 db 句柄。
// 调用方不应跨包使用此方法。
func (s *AppReleaseService) DB() *gorm.DB { return s.db }

// ReleaseDir 返回配置的 APK 发布根目录，用于 X-Accel-Redirect 路径计算。
func (s *AppReleaseService) ReleaseDir() string { return s.releaseDir }

// MaxSize 返回管理员上传 APK 的字节上限。
func (s *AppReleaseService) MaxSize() int64 { return s.maxSize }

// DecideUpdate 根据客户端当前版本、最新版本与最低支持版本号推导更新决策。
//
//	current >= latest                            → none
//	minimumSupported <= current < latest         → optional
//	current < minimumSupported                   → required
//
// 任何 versionCode <= 0 都视为非法输入并返回 UpdateNone，调用方应在更外层
// 拒绝非法请求而不是依赖此函数的回退。
func DecideUpdate(current, latest, minimumSupported int64) UpdateDecision {
	if current <= 0 || latest <= 0 || minimumSupported <= 0 {
		return UpdateNone
	}
	if current >= latest {
		return UpdateNone
	}
	if current < minimumSupported {
		return UpdateRequired
	}
	return UpdateOptional
}

// GetLatestPublished 返回指定平台和渠道下 status=published 的最高 version_code 行。
//
// 阶段 A 没有超管发布接口，测试或本地联调都通过直接 INSERT 数据进行。
// 没有任何已发布版本时返回 gorm.ErrRecordNotFound。
func (s *AppReleaseService) GetLatestPublished(ctx context.Context, platform, channel string) (*models.AppRelease, error) {
	if platform == "" || channel == "" {
		return nil, fmt.Errorf("platform and channel are required")
	}
	var release models.AppRelease
	err := s.db.WithContext(ctx).
		Where("platform = ? AND channel = ? AND status = ?", platform, channel, models.AppReleaseStatusPublished).
		Order("version_code DESC").
		First(&release).Error
	if err != nil {
		return nil, err
	}
	return &release, nil
}

// LocateAPK 把数据库里受控的 StorageKey 还原为磁盘绝对路径，并拒绝任何形式的
// 路径穿越。StorageKey 形如 `android/stable/1602/xxx.apk`，不允许以 / 开头、
// 不允许包含 .. 或绝对路径段，最终结果必须严格位于 releaseDir 内。
func (s *AppReleaseService) LocateAPK(release *models.AppRelease) (string, error) {
	if release == nil {
		return "", errors.New("release is nil")
	}
	key := release.StorageKey
	if key == "" {
		return "", errors.New("storage key is empty")
	}
	// storage key 规范是 UNIX 风格，不应该出现反斜杠或空字节。
	if strings.ContainsAny(key, "\\\x00") {
		return "", errors.New("storage key contains illegal characters")
	}
	// 拒绝任何形式的 .. 序列，包括 ".."、".." 作段、以及 "..prefix" 等组合。
	// 合法的 storage key 永远不需要 .. 字面量。
	if strings.Contains(key, "..") {
		return "", errors.New("storage key must not contain traversal segments")
	}
	if filepath.IsAbs(key) {
		return "", errors.New("storage key must be relative")
	}
	for _, seg := range strings.Split(key, "/") {
		if seg == "" {
			return "", errors.New("storage key contains empty segment")
		}
	}

	combined := filepath.Join(s.releaseDir, filepath.FromSlash(key))
	absReleaseDir, err := filepath.Abs(s.releaseDir)
	if err != nil {
		return "", fmt.Errorf("resolve release dir: %w", err)
	}
	absCombined, err := filepath.Abs(combined)
	if err != nil {
		return "", fmt.Errorf("resolve apk path: %w", err)
	}
	rel, err := filepath.Rel(absReleaseDir, absCombined)
	if err != nil {
		return "", fmt.Errorf("verify apk path: %w", err)
	}
	// 兜底：拼接后的最终结果必须在 releaseDir 内。
	if rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", errors.New("apk path escapes release dir")
	}
	return absCombined, nil
}
