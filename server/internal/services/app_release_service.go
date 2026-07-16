package services

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
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
	db        *gorm.DB
	releaseDir string
}

// NewAppReleaseService 构造一个 AppReleaseService。releaseDir 是配置中的
// APP_RELEASE_DIR，唯一用途是 LocateAPK 的路径解析。
func NewAppReleaseService(db *gorm.DB, releaseDir string) *AppReleaseService {
	return &AppReleaseService{db: db, releaseDir: releaseDir}
}

// DecideUpdate 根据客户端当前版本、最新版本与最低支持版本号推导更新决策。
//
//   current >= latest                            → none
//   minimumSupported <= current < latest         → optional
//   current < minimumSupported                   → required
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