package services

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"shenliyuan/internal/models"

	"github.com/google/uuid"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// ThemeSubmitOptions 承载主题包投稿的请求级参数。
type ThemeSubmitOptions struct {
	IdempotencyKey  string
	FamilyID        string
	RequestedSource string
	Overrides       ThemeMetadataOverrides
}

// ThemePackService 管理主题包投稿、规范化落盘、审核并发锁、目录及孤儿目录回收。
type ThemePackService struct {
	DB   *gorm.DB
	root string
}

func NewThemePackService(db *gorm.DB, uploadDir string) *ThemePackService {
	return &ThemePackService{
		DB:   db,
		root: filepath.Join(uploadDir, ".theme-packs"),
	}
}

func (s *ThemePackService) PackDir(id string) string {
	return filepath.Join(s.root, id)
}

// IsStoreEnabled 读取系统动态配置中的商城开关，未配置时默认开启。
func (s *ThemePackService) IsStoreEnabled(ctx context.Context) bool {
	if s == nil || s.DB == nil || !s.DB.Migrator().HasTable(&models.SystemConfig{}) {
		return true
	}
	var cfg models.SystemConfig
	if err := s.DB.WithContext(ctx).First(&cfg, "config_key = ?", "theme_store_enabled").Error; err != nil {
		return true
	}
	v := strings.ToLower(strings.TrimSpace(cfg.ConfigValue))
	return v != "false" && v != "0" && v != "off"
}

const officialThemeReleasePrefix = "official-release-"

// Submit 分锁外校验重编码与锁内确定版本号打包两段执行，保证 DB 版本与规范包内 manifest 完全一致。
func (s *ThemePackService) Submit(ctx context.Context, userID uint, opts ThemeSubmitOptions, rawZip []byte) (*models.ThemePack, error) {
	return s.submit(ctx, userID, opts, rawZip, "")
}

// PublishOfficialRelease 供发布 CLI 登记已经批准分发的内置主题。HTTP 投稿不调用此入口。
func (s *ThemePackService) PublishOfficialRelease(ctx context.Context, authorID uint, releaseCommit string, overrides ThemeMetadataOverrides, rawZip []byte) (*models.ThemePack, error) {
	if _, err := hex.DecodeString(releaseCommit); err != nil || len(releaseCommit) != 40 || releaseCommit != strings.ToLower(releaseCommit) {
		return nil, themeFieldError("releaseCommit")
	}
	return s.submit(ctx, authorID, ThemeSubmitOptions{
		IdempotencyKey:  officialThemeReleasePrefix + releaseCommit,
		RequestedSource: models.ThemeSourceOfficial,
		Overrides:       overrides,
	}, rawZip, releaseCommit)
}

func (s *ThemePackService) submit(ctx context.Context, userID uint, opts ThemeSubmitOptions, rawZip []byte, releaseCommit string) (*models.ThemePack, error) {
	opts.IdempotencyKey = strings.TrimSpace(opts.IdempotencyKey)
	opts.FamilyID = strings.ToLower(strings.TrimSpace(opts.FamilyID))
	opts.RequestedSource = strings.TrimSpace(opts.RequestedSource)

	if userID == 0 {
		return nil, newThemeError(http.StatusForbidden, ThemeCodeForbidden, "", "无权操作")
	}
	if !themeIdemKeyPattern.MatchString(opts.IdempotencyKey) ||
		(releaseCommit == "" && strings.HasPrefix(opts.IdempotencyKey, officialThemeReleasePrefix)) {
		return nil, themeFieldError("idempotencyKey")
	}
	if opts.FamilyID != "" && !themeUUIDPattern.MatchString(opts.FamilyID) {
		return nil, themeFieldError("familyId")
	}
	if opts.RequestedSource != "" && opts.RequestedSource != models.ThemeSourceCommunity && opts.RequestedSource != models.ThemeSourceOfficial {
		return nil, themeFieldError("source")
	}

	var preUser models.User
	if err := s.DB.WithContext(ctx).Select("id", "account_status", "role", "nickname").First(&preUser, userID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, newThemeError(http.StatusForbidden, ThemeCodeForbidden, "", "账号不可用")
		}
		return nil, err
	}
	if preUser.AccountStatus != "" && preUser.AccountStatus != "active" {
		return nil, newThemeError(http.StatusForbidden, ThemeCodeForbidden, "", "账号处于受限或注销状态，无法投稿")
	}

	if releaseCommit != "" && preUser.Role != models.RoleSuperAdmin {
		return nil, newThemeError(http.StatusForbidden, ThemeCodeForbidden, "", "官方发布需要应用超级管理员署名")
	}

	// 锁外幂等快速路径：同一用户同一幂等键直接返回原记录，不比对请求摘要。
	var existing models.ThemePack
	if err := s.DB.WithContext(ctx).Where("author_user_id = ? AND idempotency_key = ?", userID, opts.IdempotencyKey).First(&existing).Error; err == nil {
		return &existing, nil
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, err
	}

	validated, err := ValidateAndNormalizeThemePack(rawZip, opts.Overrides)
	if err != nil {
		return nil, err
	}

	if err := os.MkdirAll(s.root, 0700); err != nil {
		return nil, err
	}
	stage, err := os.MkdirTemp(s.root, ".stage-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(stage)

	if err := os.WriteFile(filepath.Join(stage, "preview_light.jpg"), validated.PreviewLightJPG, 0600); err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(stage, "preview_dark.jpg"), validated.PreviewDarkJPG, 0600); err != nil {
		return nil, err
	}

	var created models.ThemePack
	var destination string
	committed := false
	defer func() {
		if !committed && destination != "" {
			_ = os.RemoveAll(destination)
		}
	}()

	err = s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, userID).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return newThemeError(http.StatusForbidden, ThemeCodeForbidden, "", "账号不可用")
			}
			return err
		}
		if user.AccountStatus != "" && user.AccountStatus != "active" {
			return newThemeError(http.StatusForbidden, ThemeCodeForbidden, "", "账号处于受限或注销状态，无法投稿")
		}

		if releaseCommit != "" && user.Role != models.RoleSuperAdmin {
			return newThemeError(http.StatusForbidden, ThemeCodeForbidden, "", "官方发布需要应用超级管理员署名")
		}

		// 锁内再次核对幂等键，防止并发重复请求生成两条记录。
		if err := tx.Where("author_user_id = ? AND idempotency_key = ?", userID, opts.IdempotencyKey).First(&existing).Error; err == nil {
			return nil
		} else if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}

		finalSource := models.ThemeSourceCommunity
		if opts.RequestedSource == models.ThemeSourceOfficial && (user.Role == models.RoleAdmin || user.Role == models.RoleSuperAdmin) {
			finalSource = models.ThemeSourceOfficial
		}
		if finalSource == models.ThemeSourceCommunity {
			if strings.HasPrefix(validated.Name, "官方") || strings.HasPrefix(validated.Name, "沈理") || strings.HasPrefix(validated.Name, "沈阳理工") {
				return themeFieldError("name")
			}
		}

		var pendingCount int64
		if err := tx.Model(&models.ThemePack{}).
			Where("author_user_id = ? AND status = ?", userID, models.ThemeStatusPending).
			Count(&pendingCount).Error; err != nil {
			return err
		}
		if pendingCount >= 3 {
			return newThemeError(http.StatusTooManyRequests, ThemeCodeQuota, "", "待审核主题已达 3 个上限，请等待审核或撤回后再试")
		}

		var recentCount int64
		cutoff := time.Now().Add(-24 * time.Hour)
		if err := tx.Model(&models.ThemePack{}).
			Where("author_user_id = ? AND created_at >= ?", userID, cutoff).
			Count(&recentCount).Error; err != nil {
			return err
		}
		if recentCount >= 5 {
			return newThemeError(http.StatusTooManyRequests, ThemeCodeQuota, "", "24 小时内最多投稿 5 个主题，请稍后再试")
		}

		packID := uuid.NewString()
		familyID := packID
		version := 1
		status := models.ThemeStatusPending

		if releaseCommit != "" {
			// 保留内置包的版本族身份，使已内置的主题能与商城详情对应。
			packID = validated.Manifest["id"].(string)
			familyID = packID
			version = validated.Manifest["version"].(int)
			status = models.ThemeStatusApproved
		} else if opts.FamilyID != "" {
			familyID = opts.FamilyID
			var root models.ThemePack
			if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&root, "id = ?", familyID).Error; err != nil {
				if errors.Is(err, gorm.ErrRecordNotFound) {
					return newThemeError(http.StatusNotFound, ThemeCodeNotFound, "familyId", "原主题作品不存在")
				}
				return err
			}
			if root.FamilyID != root.ID {
				return newThemeError(http.StatusNotFound, ThemeCodeNotFound, "familyId", "原主题作品不存在")
			}
			if root.AuthorUserID != userID {
				return newThemeError(http.StatusForbidden, ThemeCodeForbidden, "familyId", "只能为自己的作品发布新版本")
			}
			if root.Status == models.ThemeStatusRemoved || root.Status == models.ThemeStatusWithdrawn {
				return newThemeError(http.StatusConflict, ThemeCodeConflict, "familyId", "该主题已下架或撤回，不能再发布新版本")
			}
			var maxVer int
			if err := tx.Model(&models.ThemePack{}).
				Where("family_id = ?", familyID).
				Select("COALESCE(MAX(version), 0)").
				Scan(&maxVer).Error; err != nil {
				return err
			}
			version = maxVer + 1
		}

		authorName := strings.TrimSpace(user.Nickname)
		if authorName == "" {
			authorName = "匿名作者"
		}
		if utf8.RuneCountInString(authorName) > 20 {
			rs := []rune(authorName)
			authorName = string(rs[:20])
		}

		validated.Manifest["id"] = familyID
		validated.Manifest["version"] = version
		validated.Manifest["author"] = authorName
		validated.Manifest["source"] = finalSource

		manifestBytes, err := marshalCanonicalJSON(validated.Manifest)
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(stage, "manifest.json"), manifestBytes, 0600); err != nil {
			return err
		}
		pkgBytes, err := buildNormalizedPackageZip(manifestBytes, validated.NormalizedFiles)
		if err != nil {
			return err
		}
		pkgPath := filepath.Join(stage, "package.sltheme")
		if err := os.WriteFile(pkgPath, pkgBytes, 0600); err != nil {
			return err
		}

		// 服务端仅在生成规范包时计算一次 SHA-256。
		sum := sha256.Sum256(pkgBytes)
		pkgHash := hex.EncodeToString(sum[:])

		destination = filepath.Join(s.root, packID)
		if err := os.Rename(stage, destination); err != nil {
			destination = ""
			return err
		}

		created = models.ThemePack{
			ID:              packID,
			FamilyID:        familyID,
			Version:         version,
			AuthorUserID:    userID,
			Name:            validated.Name,
			Description:     validated.Description,
			Tags:            validated.Tags,
			License:         validated.License,
			Source:          finalSource,
			Status:          status,
			MinAppVersion:   validated.MinAppVersion,
			FontCopyright:   validated.FontCopyright,
			FontLicenseNote: validated.FontLicenseNote,
			PackageSHA256:   pkgHash,
			PackageSize:     int64(len(pkgBytes)),
			IdempotencyKey:  opts.IdempotencyKey,
		}
		if err := tx.Create(&created).Error; err != nil {
			return err
		}
		if releaseCommit == "" {
			var adminIDs []uint
			if err := tx.Model(&models.User{}).
				Where("role IN ? AND (account_status = ? OR account_status = ?) AND id <> ?",
					[]models.Role{models.RoleAdmin, models.RoleSuperAdmin}, "active", "", userID).
				Pluck("id", &adminIDs).Error; err != nil {
				return err
			}
			notifications := make([]models.Notification, 0, len(adminIDs))
			for _, adminID := range adminIDs {
				notifications = append(notifications, models.Notification{
					UserID:  adminID,
					Type:    "theme_pending",
					Content: fmt.Sprintf("有新的主题上线申请：《%s》v%d，请前往主题审核处理", created.Name, created.Version),
					FromUID: userID,
				})
			}
			if len(notifications) > 0 {
				return tx.CreateInBatches(&notifications, 200).Error
			}
			return nil
		}
		return tx.Create(&models.AdminLog{
			AdminID:   userID,
			AdminName: user.Nickname,
			Action:    "发布内置官方主题",
			Target:    familyID,
			Detail:    fmt.Sprintf("%s v%d，App 发布提交 %s", created.Name, created.Version, releaseCommit),
		}).Error
	})
	if err != nil {
		return nil, err
	}
	if existing.ID != "" {
		return &existing, nil
	}
	committed = true
	return &created, nil
}

func marshalCanonicalJSON(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

func buildNormalizedPackageZip(manifestBytes []byte, files map[string][]byte) ([]byte, error) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)

	writeEntry := func(name string, content []byte) error {
		hdr := &zip.FileHeader{
			Name:   name,
			Method: zip.Deflate,
		}
		w, err := zw.CreateHeader(hdr)
		if err != nil {
			return err
		}
		_, err = w.Write(content)
		return err
	}

	if err := writeEntry("manifest.json", manifestBytes); err != nil {
		return nil, err
	}
	paths := make([]string, 0, len(files))
	for p := range files {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		if err := writeEntry(p, files[p]); err != nil {
			return nil, err
		}
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// Review 在根记录行锁保护下执行通过或拒绝，保证同一版本族最多一条 approved 且版本号单调前进。
func (s *ThemePackService) Review(ctx context.Context, id string, adminID uint, approve bool, reasonCode, note string) (*models.ThemePack, error) {
	id = strings.ToLower(strings.TrimSpace(id))
	reasonCode = strings.TrimSpace(reasonCode)
	note = strings.TrimSpace(note)

	if !themeUUIDPattern.MatchString(id) {
		return nil, newThemeError(http.StatusNotFound, ThemeCodeNotFound, "", "主题投稿不存在")
	}
	if !approve {
		if _, ok := ThemeReviewReasonMessages[reasonCode]; !ok {
			return nil, themeFieldError("reasonCode")
		}
	}
	if utf8.RuneCountInString(note) > 500 {
		return nil, themeFieldError("note")
	}

	var updated models.ThemePack
	err := s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var admin models.User
		if err := tx.Clauses(clause.Locking{Strength: "SHARE"}).First(&admin, adminID).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return newThemeError(http.StatusForbidden, ThemeCodeForbidden, "", "无管理员权限")
			}
			return err
		}
		if (admin.AccountStatus != "" && admin.AccountStatus != "active") || (admin.Role != models.RoleAdmin && admin.Role != models.RoleSuperAdmin) {
			return newThemeError(http.StatusForbidden, ThemeCodeForbidden, "", "无管理员权限")
		}

		var probe models.ThemePack
		if err := tx.First(&probe, "id = ?", id).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return newThemeError(http.StatusNotFound, ThemeCodeNotFound, "", "主题投稿不存在")
			}
			return err
		}
		if probe.AuthorUserID == adminID {
			return newThemeError(http.StatusForbidden, ThemeCodeForbidden, "", "管理员不能审核自己的投稿")
		}

		// 先锁版本族根记录，再锁目标记录，消除并发审核 v2/v3 死锁与双 approved 竞态。
		var root models.ThemePack
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&root, "id = ?", probe.FamilyID).Error; err != nil {
			return err
		}
		if (root.Status == models.ThemeStatusRemoved || root.Status == models.ThemeStatusWithdrawn) && root.ID != probe.ID {
			return newThemeError(http.StatusConflict, ThemeCodeConflict, "", "该主题作品已下架或撤回")
		}

		var target models.ThemePack
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&target, "id = ?", id).Error; err != nil {
			return err
		}
		if target.Status != models.ThemeStatusPending {
			return newThemeError(http.StatusConflict, ThemeCodeConflict, "", "该投稿已处理，请刷新后查看")
		}

		now := time.Now()
		if approve {
			var higherOrEqual int64
			if err := tx.Model(&models.ThemePack{}).
				Where("family_id = ? AND status = ? AND version >= ?", target.FamilyID, models.ThemeStatusApproved, target.Version).
				Count(&higherOrEqual).Error; err != nil {
				return err
			}
			if higherOrEqual > 0 {
				return newThemeError(http.StatusConflict, ThemeCodeConflict, "", "已有更高或相同版本上架，不能回退旧版本")
			}

			if err := tx.Model(&models.ThemePack{}).
				Where("family_id = ? AND status = ?", target.FamilyID, models.ThemeStatusApproved).
				Update("status", models.ThemeStatusSuperseded).Error; err != nil {
				return err
			}

			var lowerPending []models.ThemePack
			if err := tx.Where("family_id = ? AND status = ? AND version < ?", target.FamilyID, models.ThemeStatusPending, target.Version).
				Order("version ASC").
				Find(&lowerPending).Error; err != nil {
				return err
			}
			if len(lowerPending) > 0 {
				if err := tx.Model(&models.ThemePack{}).
					Where("family_id = ? AND status = ? AND version < ?", target.FamilyID, models.ThemeStatusPending, target.Version).
					Update("status", models.ThemeStatusSuperseded).Error; err != nil {
					return err
				}
				for _, lp := range lowerPending {
					notif := models.Notification{
						UserID:  lp.AuthorUserID,
						Type:    "theme_review",
						Content: fmt.Sprintf("你的主题《%s》v%d 已被 v%d 取代", lp.Name, lp.Version, target.Version),
						FromUID: adminID,
					}
					if err := tx.Create(&notif).Error; err != nil {
						return err
					}
				}
			}

			res := tx.Model(&models.ThemePack{}).
				Where("id = ? AND status = ?", target.ID, models.ThemeStatusPending).
				Updates(map[string]any{
					"status":             models.ThemeStatusApproved,
					"review_reason_code": "",
					"review_note":        note,
					"reviewed_by":        adminID,
					"reviewed_at":        now,
				})
			if res.Error != nil {
				return res.Error
			}
			if res.RowsAffected != 1 {
				return newThemeError(http.StatusConflict, ThemeCodeConflict, "", "状态已变化，请刷新后重试")
			}

			if err := tx.Create(&models.AdminLog{
				AdminID:   adminID,
				AdminName: admin.Nickname,
				Action:    "审核通过主题",
				Target:    target.ID,
				Detail:    fmt.Sprintf("%s v%d (%s)", target.Name, target.Version, target.FamilyID),
			}).Error; err != nil {
				return err
			}
			if err := tx.Create(&models.Notification{
				UserID:  target.AuthorUserID,
				Type:    "theme_review",
				Content: fmt.Sprintf("你的主题《%s》v%d 已审核通过并上架", target.Name, target.Version),
				FromUID: adminID,
			}).Error; err != nil {
				return err
			}
		} else {
			res := tx.Model(&models.ThemePack{}).
				Where("id = ? AND status = ?", target.ID, models.ThemeStatusPending).
				Updates(map[string]any{
					"status":             models.ThemeStatusRejected,
					"review_reason_code": reasonCode,
					"review_note":        note,
					"reviewed_by":        adminID,
					"reviewed_at":        now,
				})
			if res.Error != nil {
				return res.Error
			}
			if res.RowsAffected != 1 {
				return newThemeError(http.StatusConflict, ThemeCodeConflict, "", "状态已变化，请刷新后重试")
			}

			reasonText := ThemeReviewReasonMessages[reasonCode]
			detail := reasonText
			if note != "" {
				detail = reasonText + "：" + note
			}
			if err := tx.Create(&models.AdminLog{
				AdminID:   adminID,
				AdminName: admin.Nickname,
				Action:    "拒绝主题投稿",
				Target:    target.ID,
				Detail:    fmt.Sprintf("%s v%d [%s] %s", target.Name, target.Version, reasonCode, note),
			}).Error; err != nil {
				return err
			}
			if err := tx.Create(&models.Notification{
				UserID:  target.AuthorUserID,
				Type:    "theme_review",
				Content: fmt.Sprintf("你的主题《%s》v%d 未通过审核：%s", target.Name, target.Version, detail),
				FromUID: adminID,
			}).Error; err != nil {
				return err
			}
		}

		return tx.First(&updated, "id = ?", target.ID).Error
	})
	if err != nil {
		return nil, err
	}
	return &updated, nil
}

// Withdraw 撤回本人投稿：待审仅撤回单版本；已上架则撤回整个版本族的公开与待审记录。
func (s *ThemePackService) Withdraw(ctx context.Context, id string, userID uint) error {
	id = strings.ToLower(strings.TrimSpace(id))
	if !themeUUIDPattern.MatchString(id) {
		return newThemeError(http.StatusNotFound, ThemeCodeNotFound, "", "主题投稿不存在")
	}
	return s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var probe models.ThemePack
		if err := tx.Where("id = ? AND author_user_id = ?", id, userID).First(&probe).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return newThemeError(http.StatusNotFound, ThemeCodeNotFound, "", "主题投稿不存在")
			}
			return err
		}

		var root models.ThemePack
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&root, "id = ?", probe.FamilyID).Error; err != nil {
			return err
		}
		var target models.ThemePack
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&target, "id = ?", id).Error; err != nil {
			return err
		}

		switch target.Status {
		case models.ThemeStatusPending:
			return tx.Model(&models.ThemePack{}).
				Where("id = ?", target.ID).
				Update("status", models.ThemeStatusWithdrawn).Error
		case models.ThemeStatusApproved:
			return tx.Model(&models.ThemePack{}).
				Where("family_id = ? AND (status IN ? OR id = ?)",
					target.FamilyID,
					[]string{models.ThemeStatusApproved, models.ThemeStatusSuperseded, models.ThemeStatusPending},
					target.FamilyID,
				).
				Update("status", models.ThemeStatusWithdrawn).Error
		default:
			return newThemeError(http.StatusConflict, ThemeCodeConflict, "", "当前状态不支持撤回")
		}
	})
}

// Remove 下架整个版本族并记录原因。
func (s *ThemePackService) Remove(ctx context.Context, familyID string, adminID uint, reasonCode, note string) error {
	familyID = strings.ToLower(strings.TrimSpace(familyID))
	reasonCode = strings.TrimSpace(reasonCode)
	note = strings.TrimSpace(note)

	if !themeUUIDPattern.MatchString(familyID) {
		return newThemeError(http.StatusNotFound, ThemeCodeNotFound, "", "主题不存在")
	}
	if _, ok := ThemeReviewReasonMessages[reasonCode]; !ok {
		return themeFieldError("reasonCode")
	}
	if utf8.RuneCountInString(note) > 500 {
		return themeFieldError("note")
	}

	return s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var admin models.User
		if err := tx.Clauses(clause.Locking{Strength: "SHARE"}).First(&admin, adminID).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return newThemeError(http.StatusForbidden, ThemeCodeForbidden, "", "无管理员权限")
			}
			return err
		}
		if (admin.AccountStatus != "" && admin.AccountStatus != "active") || (admin.Role != models.RoleAdmin && admin.Role != models.RoleSuperAdmin) {
			return newThemeError(http.StatusForbidden, ThemeCodeForbidden, "", "无管理员权限")
		}
		return RemoveThemeFamilyInTx(tx, familyID, adminID, admin.Nickname, reasonCode, note)
	})
}

// RemoveThemeFamilyInTx 供管理员下架路由与举报确认治理复用同一把根记录锁。
func RemoveThemeFamilyInTx(tx *gorm.DB, familyID string, adminID uint, adminName, reasonCode, note string) error {
	var root models.ThemePack
	if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&root, "id = ?", familyID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return newThemeError(http.StatusNotFound, ThemeCodeNotFound, "", "主题不存在")
		}
		return err
	}
	if root.FamilyID != root.ID {
		return newThemeError(http.StatusNotFound, ThemeCodeNotFound, "", "主题不存在")
	}
	now := time.Now()
	if err := tx.Model(&models.ThemePack{}).
		Where("family_id = ?", familyID).
		Updates(map[string]any{
			"status":             models.ThemeStatusRemoved,
			"review_reason_code": reasonCode,
			"review_note":        note,
			"reviewed_by":        adminID,
			"reviewed_at":        now,
		}).Error; err != nil {
		return err
	}
	reasonText := ThemeReviewReasonMessages[reasonCode]
	if reasonText == "" {
		reasonText = reasonCode
	}
	detail := reasonText
	if note != "" {
		detail = detail + "：" + note
	}
	if err := tx.Create(&models.AdminLog{
		AdminID:   adminID,
		AdminName: adminName,
		Action:    "下架主题",
		Target:    familyID,
		Detail:    detail,
	}).Error; err != nil {
		return err
	}
	return tx.Create(&models.Notification{
		UserID:  root.AuthorUserID,
		Type:    "theme_review",
		Content: fmt.Sprintf("你的主题《%s》已被下架：%s", root.Name, detail),
		FromUID: adminID,
	}).Error
}

// IncrementDownload 在无 Range 或 Range 从 0 开始时对版本族根记录累加下载计数。
func (s *ThemePackService) IncrementDownload(ctx context.Context, familyID string) {
	_ = s.DB.WithContext(ctx).Model(&models.ThemePack{}).
		Where("id = ?", familyID).
		UpdateColumn("downloads", gorm.Expr("downloads + 1")).Error
}

// ReadStoredManifest 读取投稿目录下的规范化 manifest.json；旧目录没有单独落盘时从 package.sltheme 读取。
func (s *ThemePackService) ReadStoredManifest(id string) map[string]any {
	if !themeUUIDPattern.MatchString(id) {
		return nil
	}
	manifestPath := filepath.Join(s.root, id, "manifest.json")
	if raw, err := os.ReadFile(manifestPath); err == nil {
		var m map[string]any
		if json.Unmarshal(raw, &m) == nil {
			return m
		}
	}
	pkgPath := filepath.Join(s.root, id, "package.sltheme")
	zr, err := zip.OpenReader(pkgPath)
	if err != nil {
		return nil
	}
	defer zr.Close()
	for _, f := range zr.File {
		if f.Name == "manifest.json" {
			rc, err := f.Open()
			if err != nil {
				return nil
			}
			defer rc.Close()
			var m map[string]any
			if json.NewDecoder(rc).Decode(&m) == nil {
				return m
			}
		}
	}
	return nil
}

// CleanupOrphans 仅清理超过 24 小时的 .stage-* 暂存目录及无有效数据库记录或已撤回的目录。
func (s *ThemePackService) CleanupOrphans(ctx context.Context) error {
	entries, err := os.ReadDir(s.root)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, entry := range entries {
		name := entry.Name()
		if !entry.IsDir() || (!strings.HasPrefix(name, ".stage-") && !themeUUIDPattern.MatchString(name)) {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if time.Since(info.ModTime()) < 24*time.Hour {
			continue
		}
		if strings.HasPrefix(name, ".stage-") {
			if err := os.RemoveAll(filepath.Join(s.root, name)); err != nil {
				return err
			}
			continue
		}
		var count int64
		if err := s.DB.WithContext(ctx).Model(&models.ThemePack{}).
			Where("id = ? AND status <> ?", name, models.ThemeStatusWithdrawn).
			Count(&count).Error; err != nil {
			return err
		}
		if count == 0 {
			if err := os.RemoveAll(filepath.Join(s.root, name)); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *ThemePackService) Maintain(ctx context.Context) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := s.CleanupOrphans(ctx); err != nil {
				log.Printf("theme pack maintenance unavailable: %v", err)
			}
		}
	}
}

// WithdrawThemePacksForUser 在账号注销事务中立即撤回本人全部主题投稿并停止公开访问。
func WithdrawThemePacksForUser(tx *gorm.DB, userID uint) error {
	if !tx.Migrator().HasTable(&models.ThemePack{}) {
		return nil
	}
	return tx.Model(&models.ThemePack{}).
		Where("author_user_id = ? AND status <> ?", userID, models.ThemeStatusRemoved).
		Update("status", models.ThemeStatusWithdrawn).Error
}
