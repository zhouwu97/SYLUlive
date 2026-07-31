package models

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"gorm.io/gorm"
)

// PrepareCompetitionCatalogMigration 先为已有赛事表建立可安全回填的目录权限列。
// PostgreSQL 无法直接给有数据的表新增无默认值的 NOT NULL 列，因此必须在
// AutoMigrate 前完成加列、回填和约束收紧；整个 PostgreSQL 流程在同一事务内执行。
func PrepareCompetitionCatalogMigration(db *gorm.DB) error {
	if db == nil {
		return fmt.Errorf("database is nil")
	}
	if err := prepareCompetitionCatalogPackageRevisionMigration(db); err != nil {
		return err
	}
	if !db.Migrator().HasTable(&CompetitionEvent{}) {
		return nil
	}

	switch strings.ToLower(db.Dialector.Name()) {
	case "postgres":
		return db.Transaction(func(tx *gorm.DB) error {
			statements := []string{
				"ALTER TABLE competition_events ADD COLUMN IF NOT EXISTS search_display_allowed boolean",
				"ALTER TABLE competition_events ADD COLUMN IF NOT EXISTS candidate_pool_allowed boolean",
				"ALTER TABLE competition_events ADD COLUMN IF NOT EXISTS personalized_ranking_allowed boolean",
				"ALTER TABLE competition_events ADD COLUMN IF NOT EXISTS strong_recommendation_eligible boolean",
				"ALTER TABLE competition_events ADD COLUMN IF NOT EXISTS recommendation_permission_level varchar(20)",
				"ALTER TABLE competition_events ADD COLUMN IF NOT EXISTS ai_mode varchar(40)",
				"UPDATE competition_events SET search_display_allowed = true WHERE search_display_allowed IS NULL",
				"UPDATE competition_events SET candidate_pool_allowed = true WHERE candidate_pool_allowed IS NULL",
				"UPDATE competition_events SET personalized_ranking_allowed = false WHERE personalized_ranking_allowed IS NULL",
				"UPDATE competition_events SET strong_recommendation_eligible = false WHERE strong_recommendation_eligible IS NULL",
				"UPDATE competition_events SET recommendation_permission_level = 'low' WHERE recommendation_permission_level IS NULL OR recommendation_permission_level = ''",
				"UPDATE competition_events SET ai_mode = 'candidate_explanation' WHERE ai_mode IS NULL OR ai_mode = ''",
				"ALTER TABLE competition_events ALTER COLUMN search_display_allowed SET NOT NULL",
				"ALTER TABLE competition_events ALTER COLUMN candidate_pool_allowed SET NOT NULL",
				"ALTER TABLE competition_events ALTER COLUMN personalized_ranking_allowed SET DEFAULT false",
				"ALTER TABLE competition_events ALTER COLUMN personalized_ranking_allowed SET NOT NULL",
				"ALTER TABLE competition_events ALTER COLUMN strong_recommendation_eligible SET DEFAULT false",
				"ALTER TABLE competition_events ALTER COLUMN strong_recommendation_eligible SET NOT NULL",
				"ALTER TABLE competition_events ALTER COLUMN recommendation_permission_level SET DEFAULT 'low'",
				"ALTER TABLE competition_events ALTER COLUMN recommendation_permission_level SET NOT NULL",
				"ALTER TABLE competition_events ALTER COLUMN ai_mode SET DEFAULT 'candidate_explanation'",
				"ALTER TABLE competition_events ALTER COLUMN ai_mode SET NOT NULL",
			}
			for _, statement := range statements {
				if err := tx.Exec(statement).Error; err != nil {
					return err
				}
			}
			return nil
		})
	case "sqlite":
		columns := []struct {
			name       string
			definition string
		}{
			{name: "search_display_allowed", definition: "numeric NOT NULL DEFAULT 1"},
			{name: "candidate_pool_allowed", definition: "numeric NOT NULL DEFAULT 1"},
			{name: "personalized_ranking_allowed", definition: "numeric NOT NULL DEFAULT 0"},
			{name: "strong_recommendation_eligible", definition: "numeric NOT NULL DEFAULT 0"},
			{name: "recommendation_permission_level", definition: "varchar(20) NOT NULL DEFAULT 'low'"},
			{name: "ai_mode", definition: "varchar(40) NOT NULL DEFAULT 'candidate_explanation'"},
		}
		return db.Transaction(func(tx *gorm.DB) error {
			for _, column := range columns {
				if tx.Migrator().HasColumn(&CompetitionEvent{}, column.name) {
					continue
				}
				statement := fmt.Sprintf("ALTER TABLE competition_events ADD COLUMN %s %s", column.name, column.definition)
				if err := tx.Exec(statement).Error; err != nil {
					return err
				}
			}
			return nil
		})
	default:
		return fmt.Errorf("unsupported database dialect for competition catalog migration: %s", db.Dialector.Name())
	}
}

func prepareCompetitionCatalogPackageRevisionMigration(db *gorm.DB) error {
	if !db.Migrator().HasTable(&CompetitionCatalogPackage{}) {
		return nil
	}
	switch strings.ToLower(db.Dialector.Name()) {
	case "postgres":
		return db.Transaction(func(tx *gorm.DB) error {
			statements := []string{
				"ALTER TABLE competition_catalog_packages ADD COLUMN IF NOT EXISTS revision bigint",
				"UPDATE competition_catalog_packages SET revision = 1 WHERE revision IS NULL OR revision < 1",
				"ALTER TABLE competition_catalog_packages ALTER COLUMN revision SET NOT NULL",
				"ALTER TABLE competition_catalog_packages ADD COLUMN IF NOT EXISTS lifecycle_status varchar(20)",
				"UPDATE competition_catalog_packages SET lifecycle_status = CASE WHEN is_active THEN 'active' ELSE 'staged' END WHERE lifecycle_status IS NULL OR lifecycle_status = ''",
				"ALTER TABLE competition_catalog_packages ALTER COLUMN lifecycle_status SET DEFAULT 'staged'",
				"ALTER TABLE competition_catalog_packages ALTER COLUMN lifecycle_status SET NOT NULL",
				"DROP INDEX IF EXISTS idx_competition_catalog_packages_dataset_version",
			}
			for _, statement := range statements {
				if err := tx.Exec(statement).Error; err != nil {
					return err
				}
			}
			return nil
		})
	case "sqlite":
		if db.Migrator().HasIndex(&CompetitionCatalogPackage{}, "idx_competition_catalog_packages_dataset_version") {
			return db.Migrator().DropIndex(&CompetitionCatalogPackage{}, "idx_competition_catalog_packages_dataset_version")
		}
		return nil
	default:
		return fmt.Errorf("unsupported database dialect for competition catalog package migration: %s", db.Dialector.Name())
	}
}

// BackfillCompetitionCatalogMetadata 为旧赛事生成稳定兼容 ID 和保守权限。
// 该函数必须在 CompetitionEvent 新字段完成 AutoMigrate 后执行。
func BackfillCompetitionCatalogMetadata(db *gorm.DB) error {
	if db == nil {
		return fmt.Errorf("database is nil")
	}
	var events []CompetitionEvent
	if err := db.Unscoped().Where("competition_id = '' OR competition_id IS NULL").Find(&events).Error; err != nil {
		return err
	}
	emptyJSON := []byte("[]")
	for _, event := range events {
		critical := struct {
			ID                      uint       `json:"id"`
			Title                   string     `json:"title"`
			CompetitionLevel        string     `json:"competition_level"`
			SchoolRecognitionStatus string     `json:"school_recognition_status"`
			RegistrationEnd         *time.Time `json:"registration_end"`
			EventStart              *time.Time `json:"event_start"`
			Version                 int        `json:"version"`
		}{
			ID: event.ID, Title: event.Title, CompetitionLevel: event.CompetitionLevel,
			SchoolRecognitionStatus: event.SchoolRecognitionStatus,
			RegistrationEnd:         event.RegistrationEnd, EventStart: event.EventStart, Version: event.Version,
		}
		encoded, _ := json.Marshal(critical)
		sum := sha256.Sum256(encoded)
		if err := db.Unscoped().Model(&CompetitionEvent{}).Where("id = ?", event.ID).Updates(map[string]any{
			"competition_id":  fmt.Sprintf("LEGACY-%d", event.ID),
			"dataset_version": "legacy", "record_hash": hex.EncodeToString(sum[:]),
			"search_display_allowed": true, "candidate_pool_allowed": true,
			"personalized_ranking_allowed": false, "strong_recommendation_eligible": false,
			"recommendation_permission_level": "low", "ai_mode": "candidate_explanation",
			"risk_tags": emptyJSON, "blocker_codes": emptyJSON,
		}).Error; err != nil {
			return err
		}
	}
	if err := db.Exec(
		"CREATE UNIQUE INDEX IF NOT EXISTS idx_competition_events_competition_id_unique ON competition_events (competition_id)",
	).Error; err != nil {
		return err
	}
	return db.Exec(
		"CREATE UNIQUE INDEX IF NOT EXISTS idx_competition_catalog_one_active ON competition_catalog_packages (is_active) WHERE is_active = true",
	).Error
}
