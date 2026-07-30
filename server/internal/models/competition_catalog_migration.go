package models

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"time"

	"gorm.io/gorm"
)

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
