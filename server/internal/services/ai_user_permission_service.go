package services

import (
	"context"
	"errors"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

var ErrInvalidAIUserPermission = errors.New("AI 个人数据权限无效")

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

func (service *AIUserPermissionService) Set(ctx context.Context, userID uint, scope models.AIUserPermissionScope, policy models.AIUserPermissionPolicy) (models.AIUserPermission, error) {
	if service == nil || service.db == nil || userID == 0 || !isAIUserPermissionScope(scope) || !isAIUserPermissionPolicy(policy) {
		return models.AIUserPermission{}, ErrInvalidAIUserPermission
	}
	row := models.AIUserPermission{UserID: userID, Scope: scope, Policy: policy}
	if err := service.db.WithContext(ctx).Clauses(clause.OnConflict{
		Columns:   []clause.Column{{Name: "user_id"}, {Name: "scope"}},
		DoUpdates: clause.AssignmentColumns([]string{"policy", "updated_at"}),
	}).Create(&row).Error; err != nil {
		return models.AIUserPermission{}, err
	}
	return row, nil
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
