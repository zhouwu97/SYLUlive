package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

const defaultAppReleaseMaxSize int64 = 200 * 1024 * 1024

var (
	ErrAppReleaseInvalid      = errors.New("应用版本参数无效")
	ErrAppReleaseNotFound     = errors.New("应用版本不存在")
	ErrAppReleaseNotDraft     = errors.New("应用版本不是草稿状态")
	ErrAppReleaseNotPublished = errors.New("应用版本不是已发布状态")
	ErrAppReleaseNoFallback   = errors.New("不能下架唯一的已发布版本")
)

// AppReleaseDraftInput 是创建 APK 草稿时不可变的版本与发布策略字段。
type AppReleaseDraftInput struct {
	Platform                    string
	Channel                     string
	VersionName                 string
	VersionCode                 int64
	Title                       string
	Changelog                   string
	MinimumSupportedVersionCode int64
	CreatedBy                   uint
	DeliveryMode                string
	ActionURL                   string
}

// AppReleaseDraftUpdate 包含可更新的展示信息与最低支持版本。
// 已发布版本仅允许调整最低支持构建号，且只能修改当前最高发布版本，避免
// 历史版本的策略字段影响实际生效的版本策略。
type AppReleaseDraftUpdate struct {
	Title                       *string
	Changelog                   *string
	MinimumSupportedVersionCode *int64
}

// CreateDraft 将上传流先校验并写入临时文件，再移动到正式的版本目录中。
// 数据库写入失败时会清理刚移动的 APK，避免留下可被误发布的孤立文件。
func (s *AppReleaseService) CreateDraft(ctx context.Context, input AppReleaseDraftInput, fileName string, source io.Reader, maxSize int64) (*models.AppRelease, error) {
	if err := validateDraftInput(&input); err != nil {
		return nil, err
	}
	if input.DeliveryMode == models.AppReleaseDeliveryModeExternalMarket {
		if err := s.validateExternalMarketURL(input.ActionURL); err != nil {
			return nil, err
		}
	}

	var size int64
	var sha string
	var storageKey string
	var fileNameForDb string
	moved := false
	var finalPath string

	if input.DeliveryMode == models.AppReleaseDeliveryModeDirectPackage {
		if source == nil {
			return nil, fmt.Errorf("%w: APK 文件为空", ErrAppReleaseInvalid)
		}
		if !strings.EqualFold(filepath.Ext(strings.TrimSpace(fileName)), ".apk") {
			return nil, fmt.Errorf("%w: 仅支持 .apk 文件", ErrAppReleaseInvalid)
		}

		temporaryPath, apkSize, apkSha, err := s.storeTemporaryAPK(source, maxSize)
		if err != nil {
			return nil, err
		}
		defer func() { _ = os.Remove(temporaryPath) }()
		if err := s.validateAndroidAPK(ctx, temporaryPath, input.VersionName, input.VersionCode); err != nil {
			return nil, err
		}

		size = apkSize
		sha = apkSha
		storageKey = buildAppReleaseStorageKey(input.VersionName, input.VersionCode, sha)
		fileNameForDb = buildAppReleaseFileName(input.VersionName, input.VersionCode)
		finalPath = filepath.Join(s.releaseDir, filepath.FromSlash(storageKey))

		if err := os.MkdirAll(filepath.Dir(finalPath), 0o750); err != nil {
			return nil, fmt.Errorf("创建 APK 发布目录: %w", err)
		}
		if _, err := os.Stat(finalPath); err == nil {
			return nil, fmt.Errorf("%w: 相同版本文件已存在", ErrAppReleaseInvalid)
		} else if !errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("检查 APK 目标目录: %w", err)
		}
		if err := os.Rename(temporaryPath, finalPath); err != nil {
			return nil, fmt.Errorf("移动 APK 到发布目录: %w", err)
		}
		moved = true
		defer func() {
			if moved {
				_ = os.Remove(finalPath)
			}
		}()
	} else {
		// External market doesn't need a file
		fileNameForDb = ""
		storageKey = ""
		size = 0
		sha = ""
	}

	release := &models.AppRelease{
		Platform:                    input.Platform,
		Channel:                     input.Channel,
		VersionName:                 input.VersionName,
		VersionCode:                 input.VersionCode,
		Title:                       input.Title,
		Changelog:                   input.Changelog,
		MinimumSupportedVersionCode: input.MinimumSupportedVersionCode,
		FileName:                    fileNameForDb,
		StorageKey:                  storageKey,
		FileSize:                    size,
		SHA256:                      sha,
		DeliveryMode:                input.DeliveryMode,
		ActionURL:                   input.ActionURL,
		Status:                      models.AppReleaseStatusDraft,
		CreatedBy:                   input.CreatedBy,
	}
	if err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := validateNewReleaseVersion(tx, release); err != nil {
			return err
		}
		if err := tx.Create(release).Error; err != nil {
			return err
		}
		auditDetail := "已校验 APK SHA-256"
		if release.DeliveryMode == models.AppReleaseDeliveryModeExternalMarket {
			auditDetail = "外部市场模式发布"
		}
		return writeAppReleaseAdminLog(tx, input.CreatedBy, "创建应用版本草稿", *release, auditDetail)
	}); err != nil {
		return nil, normalizeAppReleaseDBError(err)
	}
	moved = false
	return release, nil
}

// UpdateDraft 修改草稿，或调整当前最高发布版本的最低支持构建号。
// APK 文件、版本号和平台渠道一经上传不可变。
func (s *AppReleaseService) UpdateDraft(ctx context.Context, releaseID, operatorID uint, input AppReleaseDraftUpdate) (*models.AppRelease, error) {
	var updated models.AppRelease
	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var release models.AppRelease
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&release, releaseID).Error; err != nil {
			return err
		}
		isPublished := release.Status == models.AppReleaseStatusPublished
		if release.Status != models.AppReleaseStatusDraft && !isPublished {
			return ErrAppReleaseNotDraft
		}
		if isPublished {
			if input.Title != nil || input.Changelog != nil || input.MinimumSupportedVersionCode == nil {
				return fmt.Errorf("%w: 已发布版本只能调整最低支持构建号", ErrAppReleaseInvalid)
			}
			var latest models.AppRelease
			if err := tx.Where("platform = ? AND channel = ? AND status = ?", release.Platform, release.Channel, models.AppReleaseStatusPublished).
				Order("version_code DESC, id DESC").First(&latest).Error; err != nil {
				return err
			}
			if latest.ID != release.ID {
				return fmt.Errorf("%w: 只能调整当前最高已发布版本的最低支持构建号", ErrAppReleaseInvalid)
			}
		}
		updates := map[string]interface{}{}
		if input.Title != nil {
			title := strings.TrimSpace(*input.Title)
			if title == "" || len([]rune(title)) > 120 {
				return fmt.Errorf("%w: 标题长度必须为 1 到 120", ErrAppReleaseInvalid)
			}
			updates["title"] = title
		}
		if input.Changelog != nil {
			changelog := strings.TrimSpace(*input.Changelog)
			if changelog == "" || len([]rune(changelog)) > 20000 {
				return fmt.Errorf("%w: 更新说明长度必须为 1 到 20000", ErrAppReleaseInvalid)
			}
			updates["changelog"] = changelog
		}
		if input.MinimumSupportedVersionCode != nil {
			minimum := *input.MinimumSupportedVersionCode
			if minimum <= 0 || minimum > release.VersionCode {
				return fmt.Errorf("%w: 最低支持构建号必须在 1 到当前构建号之间", ErrAppReleaseInvalid)
			}
			updates["minimum_supported_version_code"] = minimum
		}
		if len(updates) == 0 {
			return fmt.Errorf("%w: 没有可更新字段", ErrAppReleaseInvalid)
		}
		if err := tx.Model(&release).Updates(updates).Error; err != nil {
			return err
		}
		if err := tx.First(&updated, releaseID).Error; err != nil {
			return err
		}
		action := "编辑应用版本草稿"
		detail := "更新草稿元数据"
		if isPublished {
			action = "调整应用最低支持版本"
			detail = "更新当前最高已发布版本的最低支持构建号"
		}
		return writeAppReleaseAdminLog(tx, operatorID, action, updated, detail)
	})
	if err != nil {
		return nil, normalizeAppReleaseDBError(err)
	}
	return &updated, nil
}

// PublishDraft 在确认磁盘文件完整后，把草稿切换为可下载版本。
func (s *AppReleaseService) PublishDraft(ctx context.Context, releaseID, operatorID uint) (*models.AppRelease, error) {
	var published models.AppRelease
	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var release models.AppRelease
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&release, releaseID).Error; err != nil {
			return err
		}
		if release.Status != models.AppReleaseStatusDraft {
			return ErrAppReleaseNotDraft
		}
		if err := s.verifyReleaseFile(ctx, &release); err != nil {
			return err
		}
		if release.MinimumSupportedVersionCode <= 0 || release.MinimumSupportedVersionCode > release.VersionCode {
			return fmt.Errorf("%w: 最低支持构建号不合法", ErrAppReleaseInvalid)
		}
		now := time.Now().UTC()
		if err := tx.Model(&release).Updates(map[string]interface{}{
			"status":       models.AppReleaseStatusPublished,
			"published_at": now,
		}).Error; err != nil {
			return err
		}
		if err := tx.First(&published, releaseID).Error; err != nil {
			return err
		}
		return writeAppReleaseAdminLog(tx, operatorID, "发布应用版本", published, "版本已发布并可供客户端下载")
	})
	if err != nil {
		return nil, normalizeAppReleaseDBError(err)
	}
	return &published, nil
}

// WithdrawPublished 下架已发布版本。唯一可下载版本不可下架，避免把用户锁进无包可装的状态。
func (s *AppReleaseService) WithdrawPublished(ctx context.Context, releaseID, operatorID uint) (*models.AppRelease, error) {
	var withdrawn models.AppRelease
	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var release models.AppRelease
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&release, releaseID).Error; err != nil {
			return err
		}
		if release.Status != models.AppReleaseStatusPublished {
			return ErrAppReleaseNotPublished
		}
		var fallbackCount int64
		if err := tx.Model(&models.AppRelease{}).Where(
			"platform = ? AND channel = ? AND status = ? AND id <> ?",
			release.Platform, release.Channel, models.AppReleaseStatusPublished, release.ID,
		).Count(&fallbackCount).Error; err != nil {
			return err
		}
		if fallbackCount == 0 {
			return ErrAppReleaseNoFallback
		}
		if err := tx.Model(&release).Update("status", models.AppReleaseStatusWithdrawn).Error; err != nil {
			return err
		}
		if err := tx.First(&withdrawn, releaseID).Error; err != nil {
			return err
		}
		auditDetail := "APK 文件保留，停止新客户端下载"
		if withdrawn.DeliveryMode == models.AppReleaseDeliveryModeExternalMarket {
			auditDetail = "停止新客户端通过外部链接下载"
		}
		return writeAppReleaseAdminLog(tx, operatorID, "下架应用版本", withdrawn, auditDetail)
	})
	if err != nil {
		return nil, normalizeAppReleaseDBError(err)
	}
	return &withdrawn, nil
}

// DeleteDraft 只允许删除从未发布的草稿。数据库成功删除后再移除私有 APK 文件。
func (s *AppReleaseService) DeleteDraft(ctx context.Context, releaseID, operatorID uint) error {
	var storagePath string
	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var release models.AppRelease
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&release, releaseID).Error; err != nil {
			return err
		}
		if release.Status != models.AppReleaseStatusDraft {
			return ErrAppReleaseNotDraft
		}
		if release.DeliveryMode == models.AppReleaseDeliveryModeDirectPackage {
			path, err := s.LocateAPK(&release)
			if err != nil {
				return err
			}
			storagePath = path
		}
		if err := tx.Delete(&release).Error; err != nil {
			return err
		}
		return writeAppReleaseAdminLog(tx, operatorID, "删除应用版本草稿", release, "删除未发布草稿")
	})
	if err != nil {
		return normalizeAppReleaseDBError(err)
	}
	if err := os.Remove(storagePath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("删除草稿 APK 文件: %w", err)
	}
	return nil
}

func (s *AppReleaseService) storeTemporaryAPK(source io.Reader, maxSize int64) (string, int64, string, error) {
	temporaryDir := filepath.Join(s.releaseDir, "android", "stable", ".tmp")
	if err := os.MkdirAll(temporaryDir, 0o750); err != nil {
		return "", 0, "", fmt.Errorf("创建 APK 临时目录: %w", err)
	}
	temporaryFile, err := os.CreateTemp(temporaryDir, "upload-*.apk")
	if err != nil {
		return "", 0, "", fmt.Errorf("创建 APK 临时文件: %w", err)
	}
	temporaryPath := temporaryFile.Name()
	defer temporaryFile.Close()
	defer func() {
		if temporaryPath != "" {
			_ = os.Remove(temporaryPath)
		}
	}()

	hash := sha256.New()
	written, err := io.Copy(io.MultiWriter(temporaryFile, hash), io.LimitReader(source, maxSize+1))
	if err != nil {
		return "", 0, "", fmt.Errorf("写入 APK 临时文件: %w", err)
	}
	if written == 0 || written > maxSize {
		return "", 0, "", fmt.Errorf("%w: APK 文件大小必须在 1 到 %d 字节之间", ErrAppReleaseInvalid, maxSize)
	}
	if err := temporaryFile.Sync(); err != nil {
		return "", 0, "", fmt.Errorf("同步 APK 临时文件: %w", err)
	}
	if _, err := temporaryFile.Seek(0, io.SeekStart); err != nil {
		return "", 0, "", fmt.Errorf("读取 APK 文件头: %w", err)
	}
	header := make([]byte, 4)
	if _, err := io.ReadFull(temporaryFile, header); err != nil {
		return "", 0, "", fmt.Errorf("%w: APK 文件头不完整", ErrAppReleaseInvalid)
	}
	if string(header) != "PK\x03\x04" {
		return "", 0, "", fmt.Errorf("%w: APK 文件不是有效 ZIP 容器", ErrAppReleaseInvalid)
	}
	sha := hex.EncodeToString(hash.Sum(nil))
	path := temporaryPath
	temporaryPath = ""
	return path, written, sha, nil
}

func validateDraftInput(input *AppReleaseDraftInput) error {
	input.Platform = strings.TrimSpace(input.Platform)
	input.Channel = strings.TrimSpace(input.Channel)
	input.VersionName = strings.TrimSpace(input.VersionName)
	input.Title = strings.TrimSpace(input.Title)
	input.Changelog = strings.TrimSpace(input.Changelog)

	if input.DeliveryMode != models.AppReleaseDeliveryModeDirectPackage &&
		input.DeliveryMode != models.AppReleaseDeliveryModeExternalMarket {
		return fmt.Errorf("%w: 不支持的 delivery_mode", ErrAppReleaseInvalid)
	}

	if input.Channel != models.AppReleaseChannelStable {
		return fmt.Errorf("%w: 当前仅支持 stable 通道", ErrAppReleaseInvalid)
	}
	if input.Platform == models.AppReleasePlatformOhos {
		if input.DeliveryMode == models.AppReleaseDeliveryModeDirectPackage {
			return fmt.Errorf("%w: 鸿蒙版暂不支持 direct_package 模式", ErrAppReleaseInvalid)
		}
	} else if input.Platform != models.AppReleasePlatformAndroid {
		return fmt.Errorf("%w: 不支持的平台 %s", ErrAppReleaseInvalid, input.Platform)
	}

	if input.DeliveryMode == models.AppReleaseDeliveryModeExternalMarket {
		parsedURL, err := url.ParseRequestURI(input.ActionURL)
		if err != nil || parsedURL.Scheme != "https" || parsedURL.Host == "" {
			return fmt.Errorf("%w: action_url 必须是有效的 HTTPS 链接", ErrAppReleaseInvalid)
		}
		if parsedURL.User != nil {
			return fmt.Errorf("%w: action_url 不允许包含用户信息", ErrAppReleaseInvalid)
		}
		if len(input.ActionURL) > 500 {
			return fmt.Errorf("%w: action_url 过长", ErrAppReleaseInvalid)
		}
	}
	if input.VersionName == "" || len([]rune(input.VersionName)) > 32 || !regexp.MustCompile(`^[0-9A-Za-z._-]+$`).MatchString(input.VersionName) {
		return fmt.Errorf("%w: version_name 只能包含字母、数字、点、下划线和连字符", ErrAppReleaseInvalid)
	}
	if input.VersionCode <= 0 || input.MinimumSupportedVersionCode <= 0 || input.MinimumSupportedVersionCode > input.VersionCode {
		return fmt.Errorf("%w: 构建号或最低支持构建号不合法", ErrAppReleaseInvalid)
	}
	if input.Title == "" || len([]rune(input.Title)) > 120 || input.Changelog == "" || len([]rune(input.Changelog)) > 20000 {
		return fmt.Errorf("%w: 标题或更新说明不合法", ErrAppReleaseInvalid)
	}
	return nil
}

func validateNewReleaseVersion(tx *gorm.DB, release *models.AppRelease) error {
	var highest models.AppRelease
	err := tx.Where("platform = ? AND channel = ?", release.Platform, release.Channel).
		Order("version_code DESC").First(&highest).Error
	if err == nil && release.VersionCode <= highest.VersionCode {
		return fmt.Errorf("%w: version_code 必须高于已有最高值 %d", ErrAppReleaseInvalid, highest.VersionCode)
	}
	if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
		return err
	}
	var sameSHA int64
	if release.SHA256 != "" {
		if err := tx.Model(&models.AppRelease{}).Where("sha256 = ?", release.SHA256).Count(&sameSHA).Error; err != nil {
			return err
		}
		if sameSHA > 0 {
			return fmt.Errorf("%w: APK SHA-256 已被其他版本使用", ErrAppReleaseInvalid)
		}
	}
	return nil
}

func (s *AppReleaseService) verifyReleaseFile(ctx context.Context, release *models.AppRelease) error {
	if release.DeliveryMode == models.AppReleaseDeliveryModeExternalMarket {
		return nil
	}
	path, err := s.LocateAPK(release)
	if err != nil {
		return err
	}
	info, err := os.Stat(path)
	if err != nil || info.IsDir() || info.Size() != release.FileSize {
		return fmt.Errorf("%w: APK 文件不存在或大小不符", ErrAppReleaseInvalid)
	}
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("读取 APK 文件: %w", err)
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return fmt.Errorf("校验 APK SHA-256: %w", err)
	}
	if !strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), release.SHA256) {
		return fmt.Errorf("%w: APK SHA-256 不匹配", ErrAppReleaseInvalid)
	}
	return s.validateAndroidAPK(ctx, path, release.VersionName, release.VersionCode)
}

func writeAppReleaseAdminLog(tx *gorm.DB, adminID uint, action string, release models.AppRelease, detail string) error {
	var admin models.User
	if err := tx.Select("nickname").First(&admin, adminID).Error; err != nil {
		return err
	}
	return tx.Create(&models.AdminLog{
		AdminID: adminID, AdminName: admin.Nickname, Action: action,
		Target: release.VersionName + "+" + strconv.FormatInt(release.VersionCode, 10), Detail: detail,
	}).Error
}

func buildAppReleaseStorageKey(versionName string, versionCode int64, sha string) string {
	return "android/stable/" + strconv.FormatInt(versionCode, 10) + "/shenliyuan-" + versionName + "-" + strconv.FormatInt(versionCode, 10) + "-" + sha[:12] + ".apk"
}

func buildAppReleaseFileName(versionName string, versionCode int64) string {
	return "shenliyuan-" + versionName + "-" + strconv.FormatInt(versionCode, 10) + ".apk"
}

func normalizeAppReleaseDBError(err error) error {
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return ErrAppReleaseNotFound
	}
	return err
}
