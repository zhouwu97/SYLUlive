package services

import (
	"context"
	"errors"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

var ErrInvalidAIUserPermission = errors.New("AI 个人数据权限无效")

const (
	AIUserPermissionModeAsk     = "ask"
	AIUserPermissionModeTrusted = "trusted"
)

// AIUserPermissionService 管理校园 Agent 的长期个人数据授权偏好。
// 默认 ask 保持逐次确认，不会因未创建记录而扩大数据访问范围。
type AIUserPermissionService struct {
	db *gorm.DB
}

func NewAIUserPermissionService(db *gorm.DB) *AIUserPermissionService {
	return &AIUserPermissionService{db: db}
}

func (service *AIUserPermissionService) List(ctx context.Context, userID uint) ([]models.AIUserPermission, error) {
	if service == nil || service.db == nil || userID == 0 {
		return nil, ErrInvalidAIUserPermission
	}
	values := make(map[models.AIUserPermissionScope]models.AIUserPermissionPolicy, len(allAIUserPermissionScopes))
	for _, scope := range allAIUserPermissionScopes {
		values[scope] = models.AIUserPermissionAsk
	}
	var rows []models.AIUserPermission
	if err := service.db.WithContext(ctx).Where("user_id = ?", userID).Find(&rows).Error; err != nil {
		return nil, err
	}
	for _, row := range rows {
		if isAIUserPermissionScope(row.Scope) && isAIUserPermissionPolicy(row.Policy) {
			values[row.Scope] = row.Policy
		}
	}
	result := make([]models.AIUserPermission, 0, len(allAIUserPermissionScopes))
	for _, scope := range allAIUserPermissionScopes {
		result = append(result, models.AIUserPermission{UserID: userID, Scope: scope, Policy: values[scope]})
	}
	return result, nil
}

// Policy 返回一个范围的长期策略。缺省记录始终回退为 ask。
func (service *AIUserPermissionService) Policy(ctx context.Context, userID uint, scope models.AIUserPermissionScope) (models.AIUserPermissionPolicy, error) {
	if service == nil || service.db == nil || userID == 0 || !isAIUserPermissionScope(scope) {
		return models.AIUserPermissionAsk, ErrInvalidAIUserPermission
	}
	var row models.AIUserPermission
	err := service.db.WithContext(ctx).Where("user_id = ? AND scope = ?", userID, scope).First(&row).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return models.AIUserPermissionAsk, nil
	}
	if err != nil {
		return models.AIUserPermissionAsk, err
	}
	if !isAIUserPermissionPolicy(row.Policy) {
		return models.AIUserPermissionAsk, ErrInvalidAIUserPermission
	}
	return row.Policy, nil
}

// PermissionVersion 返回当前权限版本。缺少记录时返回 0，表示默认 ask。
// Scoped Grant 会在 MCP 入口重新比对该版本，确保撤权不会等到 token 自然过期。
func (service *AIUserPermissionService) PermissionVersion(ctx context.Context, userID uint, scope models.AIUserPermissionScope) (int64, error) {
	if service == nil || service.db == nil || userID == 0 || !isAIUserPermissionScope(scope) {
		return 0, ErrInvalidAIUserPermission
	}
	var row models.AIUserPermission
	err := service.db.WithContext(ctx).Select("version").Where("user_id = ? AND scope = ?", userID, scope).First(&row).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	return row.Version, nil
}

func (service *AIUserPermissionService) Set(ctx context.Context, userID uint, scope models.AIUserPermissionScope, policy models.AIUserPermissionPolicy) (models.AIUserPermission, error) {
	if service == nil || service.db == nil || userID == 0 || !isAIUserPermissionScope(scope) || !isAIUserPermissionPolicy(policy) {
		return models.AIUserPermission{}, ErrInvalidAIUserPermission
	}
	var row models.AIUserPermission
	err := service.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		err := tx.Where("user_id = ? AND scope = ?", userID, scope).First(&row).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			row = models.AIUserPermission{UserID: userID, Scope: scope, Policy: policy, Version: 1}
			return tx.Create(&row).Error
		}
		if err != nil {
			return err
		}
		if row.Version <= 0 {
			row.Version = 1
		}
		result := tx.Model(&models.AIUserPermission{}).
			Where("id = ? AND version = ?", row.ID, row.Version).
			Updates(map[string]interface{}{"policy": policy, "version": gorm.Expr("version + 1"), "updated_at": time.Now()})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return errors.New("ai_user_permission_version_conflict")
		}
		row.Policy = policy
		row.Version++
		return nil
	})
	if err != nil {
		return models.AIUserPermission{}, err
	}
	return row, nil
}

// Mode 将内部 scope 聚合为普通用户可理解的两种 Agent 工作方式。
func (service *AIUserPermissionService) Mode(ctx context.Context, userID uint) (string, error) {
	permissions, err := service.List(ctx, userID)
	if err != nil {
		return "", err
	}
	trusted := true
	for _, permission := range permissions {
		if permission.Scope != models.AIUserPermissionExternalModelAnalysis && permission.Policy != models.AIUserPermissionAlways {
			trusted = false
			break
		}
	}
	if trusted {
		return AIUserPermissionModeTrusted, nil
	}
	return AIUserPermissionModeAsk, nil
}

// SetMode 在一个事务内写入所有 Agent 只读/刷新 scope，避免逐 scope PUT 的半成功状态。
func (service *AIUserPermissionService) SetMode(ctx context.Context, userID uint, mode string) error {
	if service == nil || service.db == nil || userID == 0 ||
		(mode != AIUserPermissionModeAsk && mode != AIUserPermissionModeTrusted) {
		return ErrInvalidAIUserPermission
	}
	policy := models.AIUserPermissionAsk
	if mode == AIUserPermissionModeTrusted {
		policy = models.AIUserPermissionAlways
	}
	return service.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		for _, scope := range allAIUserPermissionScopes {
			if scope == models.AIUserPermissionExternalModelAnalysis {
				// Agent 模式不覆盖外部模型分析；该权限由独立 scope 控制。
				// 这也兼容尚未执行 20260726 CHECK 迁移的旧数据库。
				continue
			}
			row := models.AIUserPermission{UserID: userID, Scope: scope, Policy: policy}
			if err := tx.Clauses(clause.OnConflict{
				Columns: []clause.Column{{Name: "user_id"}, {Name: "scope"}},
				DoUpdates: clause.Assignments(map[string]interface{}{
					"policy": policy, "version": gorm.Expr("version + 1"), "updated_at": time.Now(),
				}),
			}).Create(&row).Error; err != nil {
				return err
			}
		}
		return nil
	})
}

var allAIUserPermissionScopes = []models.AIUserPermissionScope{
	models.AIUserPermissionPersonalDataAccess,
	models.AIUserPermissionDeviceCacheAccess,
	models.AIUserPermissionRemoteEduRefresh,
	models.AIUserPermissionErkeSnapshotUpload,
	models.AIUserPermissionAcademicCloudStorage,
	models.AIUserPermissionExternalModelAnalysis,
}

func isAIUserPermissionScope(scope models.AIUserPermissionScope) bool {
	return scope.Valid()
}

func isAIUserPermissionPolicy(policy models.AIUserPermissionPolicy) bool {
	return policy == models.AIUserPermissionAsk || policy == models.AIUserPermissionAlways || policy == models.AIUserPermissionNever
}
