package models

import (
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"gorm.io/datatypes"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const (
	CompetitionCalendarDedupMigrationVersion = "20260710_01_competition_calendar_official_unique"
	CompetitionOfficialUniqueIndex           = "idx_user_competition_official_active_unique"
	CompetitionRatingMigrationVersion        = "20260721_01_competition_rating_backfill"
)

type AppSchemaMigration struct {
	Version   string         `gorm:"primaryKey;size:100" json:"version"`
	AppliedAt time.Time      `json:"applied_at"`
	Details   datatypes.JSON `json:"details"`
}

func (AppSchemaMigration) TableName() string { return "app_schema_migrations" }

type CompetitionDuplicateGroup struct {
	UserID        uint   `json:"user_id"`
	SourceEventID uint   `json:"source_event_id"`
	KeepID        uint   `json:"keep_id"`
	DeleteIDs     []uint `json:"delete_ids"`
}

type CompetitionDedupReport struct {
	Version       string                      `json:"version"`
	Applied       bool                        `json:"applied"`
	GroupCount    int                         `json:"group_count"`
	DuplicateRows int                         `json:"duplicate_rows"`
	AffectedUsers int                         `json:"affected_users"`
	Groups        []CompetitionDuplicateGroup `json:"groups"`
}

// ApplyCompetitionRatingMigration 将旧赛事等级复制到新字段，迁移可重复执行且不会覆盖新值。
func ApplyCompetitionRatingMigration(db *gorm.DB) error {
	if err := db.AutoMigrate(&AppSchemaMigration{}); err != nil {
		return err
	}
	var applied int64
	if err := db.Model(&AppSchemaMigration{}).
		Where("version = ?", CompetitionRatingMigrationVersion).Count(&applied).Error; err != nil {
		return err
	}
	if applied > 0 {
		return nil
	}
	return db.Transaction(func(tx *gorm.DB) error {
		result := tx.Model(&CompetitionEvent{}).
			Where("(competition_rating IS NULL OR TRIM(competition_rating) = '') AND TRIM(recommendation_level) <> ''").
			UpdateColumn("competition_rating", gorm.Expr("recommendation_level"))
		if result.Error != nil {
			return result.Error
		}
		details, _ := json.Marshal(map[string]interface{}{"backfilled_rows": result.RowsAffected})
		return tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&AppSchemaMigration{
			Version:   CompetitionRatingMigrationVersion,
			AppliedAt: time.Now(),
			Details:   datatypes.JSON(details),
		}).Error
	})
}

func InspectCompetitionCalendarDuplicates(db *gorm.DB) (CompetitionDedupReport, error) {
	report := CompetitionDedupReport{Version: CompetitionCalendarDedupMigrationVersion, Groups: []CompetitionDuplicateGroup{}}
	if !db.Migrator().HasTable(&UserCompetitionCalendarItem{}) {
		return report, nil
	}
	var items []UserCompetitionCalendarItem
	if err := db.Where("source_type = ? AND source_event_id IS NOT NULL", "official").Find(&items).Error; err != nil {
		return report, err
	}
	groups := make(map[[2]uint][]UserCompetitionCalendarItem)
	for _, item := range items {
		groups[[2]uint{item.UserID, *item.SourceEventID}] = append(groups[[2]uint{item.UserID, *item.SourceEventID}], item)
	}
	affectedUsers := map[uint]struct{}{}
	for key, group := range groups {
		if len(group) < 2 {
			continue
		}
		sort.SliceStable(group, func(i, j int) bool {
			left, right := group[i], group[j]
			if left.IsCustomModified != right.IsCustomModified {
				return left.IsCustomModified
			}
			if left.IsPinned != right.IsPinned {
				return left.IsPinned
			}
			if !left.UpdatedAt.Equal(right.UpdatedAt) {
				return left.UpdatedAt.After(right.UpdatedAt)
			}
			return left.ID > right.ID
		})
		deleteIDs := make([]uint, 0, len(group)-1)
		for _, duplicate := range group[1:] {
			deleteIDs = append(deleteIDs, duplicate.ID)
		}
		report.Groups = append(report.Groups, CompetitionDuplicateGroup{
			UserID: key[0], SourceEventID: key[1], KeepID: group[0].ID, DeleteIDs: deleteIDs,
		})
		report.DuplicateRows += len(deleteIDs)
		affectedUsers[key[0]] = struct{}{}
	}
	sort.Slice(report.Groups, func(i, j int) bool {
		if report.Groups[i].UserID != report.Groups[j].UserID {
			return report.Groups[i].UserID < report.Groups[j].UserID
		}
		return report.Groups[i].SourceEventID < report.Groups[j].SourceEventID
	})
	report.GroupCount = len(report.Groups)
	report.AffectedUsers = len(affectedUsers)
	return report, nil
}

func ApplyCompetitionCalendarDedupMigration(db *gorm.DB) (CompetitionDedupReport, error) {
	if err := db.AutoMigrate(&AppSchemaMigration{}); err != nil {
		return CompetitionDedupReport{}, err
	}
	var applied int64
	if err := db.Model(&AppSchemaMigration{}).
		Where("version = ?", CompetitionCalendarDedupMigrationVersion).Count(&applied).Error; err != nil {
		return CompetitionDedupReport{}, err
	}
	report, err := InspectCompetitionCalendarDuplicates(db)
	if err != nil || applied > 0 {
		return report, err
	}
	err = db.Transaction(func(tx *gorm.DB) error {
		for _, group := range report.Groups {
			if len(group.DeleteIDs) == 0 {
				continue
			}
			if err := tx.Delete(&UserCompetitionCalendarItem{}, group.DeleteIDs).Error; err != nil {
				return err
			}
		}
		indexSQL := fmt.Sprintf(
			"CREATE UNIQUE INDEX IF NOT EXISTS %s ON user_competition_calendar_items(user_id, source_event_id) WHERE deleted_at IS NULL AND source_type = 'official' AND source_event_id IS NOT NULL",
			CompetitionOfficialUniqueIndex,
		)
		if err := tx.Exec(indexSQL).Error; err != nil {
			return fmt.Errorf("create competition unique index: %w", err)
		}
		remaining, err := InspectCompetitionCalendarDuplicates(tx)
		if err != nil {
			return err
		}
		if remaining.DuplicateRows != 0 {
			return fmt.Errorf("仍存在 %d 条有效重复记录", remaining.DuplicateRows)
		}
		details, _ := json.Marshal(report)
		return tx.Create(&AppSchemaMigration{
			Version: CompetitionCalendarDedupMigrationVersion, AppliedAt: time.Now(), Details: datatypes.JSON(details),
		}).Error
	})
	if err != nil {
		return report, err
	}
	report.Applied = true
	return report, nil
}

func VerifyCompetitionCalendarDedupMigration(db *gorm.DB) error {
	if !db.Migrator().HasTable(&AppSchemaMigration{}) {
		return fmt.Errorf("缺少迁移记录表，请先执行竞赛计划去重迁移")
	}
	var count int64
	if err := db.Model(&AppSchemaMigration{}).
		Where("version = ?", CompetitionCalendarDedupMigrationVersion).Count(&count).Error; err != nil {
		return err
	}
	if count == 0 {
		return fmt.Errorf("缺少迁移版本 %s", CompetitionCalendarDedupMigrationVersion)
	}
	if !db.Migrator().HasIndex(&UserCompetitionCalendarItem{}, CompetitionOfficialUniqueIndex) {
		return fmt.Errorf("缺少条件唯一索引 %s", CompetitionOfficialUniqueIndex)
	}
	return nil
}
