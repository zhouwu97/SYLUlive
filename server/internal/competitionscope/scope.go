package competitionscope

import (
	"context"
	"errors"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// Scope 描述当前公开查询应读取的唯一目录范围。
type Scope struct {
	ActivePackageID    *uint
	DatasetVersion     string
	LegacyFallback     bool
	UnmigratedFallback bool
}

// Resolve 在存在活动包时只允许读取该包；首次激活前才回退旧数据。
func Resolve(ctx context.Context, db *gorm.DB) (Scope, error) {
	if !db.Migrator().HasTable(&models.CompetitionCatalogPackage{}) {
		return Scope{DatasetVersion: "legacy", LegacyFallback: true, UnmigratedFallback: true}, nil
	}
	var active models.CompetitionCatalogPackage
	err := db.WithContext(ctx).Where("is_active = ?", true).First(&active).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return Scope{DatasetVersion: "legacy", LegacyFallback: true}, nil
	}
	if err != nil {
		return Scope{}, err
	}
	return Scope{ActivePackageID: &active.ID, DatasetVersion: active.DatasetVersion}, nil
}

func (scope Scope) apply(db *gorm.DB) *gorm.DB {
	if scope.UnmigratedFallback {
		return db
	}
	if scope.ActivePackageID != nil {
		return db.Where("competition_events.catalog_package_id = ?", *scope.ActivePackageID)
	}
	return db.Where(
		"competition_events.catalog_package_id IS NULL AND (competition_events.dataset_version = '' OR competition_events.dataset_version = 'legacy')",
	)
}

// ApplyPublic 限定公开赛事查询，并统一执行公开状态和展示权限门。
func (scope Scope) ApplyPublic(db *gorm.DB) *gorm.DB {
	query := scope.apply(db).Where("competition_events.status = ?", "published")
	if scope.LegacyFallback {
		return query.Where(
			"competition_events.search_display_allowed = ? OR competition_events.dataset_version = '' OR competition_events.dataset_version = 'legacy'",
			true,
		)
	}
	return query.Where("competition_events.search_display_allowed = ?", true)
}

// ApplyCandidate 在公开范围上追加候选池权限门。
func (scope Scope) ApplyCandidate(db *gorm.DB) *gorm.DB {
	query := scope.ApplyPublic(db)
	if scope.UnmigratedFallback {
		return query.Where(
			"competition_events.candidate_pool_allowed = ? OR competition_events.dataset_version = '' OR competition_events.dataset_version = 'legacy'",
			true,
		)
	}
	return query.Where("competition_events.candidate_pool_allowed = ?", true)
}

// ApplyMCPFact 与公开软件共用同一活动包事实边界。
func (scope Scope) ApplyMCPFact(db *gorm.DB) *gorm.DB {
	return scope.ApplyPublic(db)
}
