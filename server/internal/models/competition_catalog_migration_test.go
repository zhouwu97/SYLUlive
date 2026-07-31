package models

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

func TestPrepareCompetitionCatalogMigrationBackfillsLegacyRows(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "catalog-migration.db")), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })

	if err := db.Exec(`CREATE TABLE competition_events (
		id integer PRIMARY KEY AUTOINCREMENT,
		title varchar(200) NOT NULL,
		competition_level varchar(40),
		school_recognition_status varchar(32),
		version integer DEFAULT 1
	)`).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Exec("INSERT INTO competition_events (title, competition_level, school_recognition_status, version) VALUES (?, ?, ?, ?)",
		"旧赛事", "national", "recognized", 1).Error; err != nil {
		t.Fatal(err)
	}

	for range 2 {
		if err := PrepareCompetitionCatalogMigration(db); err != nil {
			t.Fatalf("预迁移应可重复执行: %v", err)
		}
	}
	if err := db.AutoMigrate(&CompetitionCatalogPackage{}, &CompetitionCatalogAuditLog{}, &CompetitionEvent{}); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := BackfillCompetitionCatalogMetadata(db); err != nil {
			t.Fatalf("回填应可重复执行: %v", err)
		}
	}

	var event CompetitionEvent
	if err := db.First(&event).Error; err != nil {
		t.Fatal(err)
	}
	if event.CompetitionID != "LEGACY-1" || event.DatasetVersion != "legacy" || event.RecordHash == "" {
		t.Fatalf("旧赛事标识回填不完整: %+v", event)
	}
	if !event.SearchDisplayAllowed || !event.CandidatePoolAllowed {
		t.Fatalf("旧赛事应保留展示和候选资格: %+v", event)
	}
	if event.PersonalizedRankingAllowed || event.StrongRecommendationEligible {
		t.Fatalf("旧赛事不得开启个性化排序或强推荐: %+v", event)
	}
	if event.RecommendationPermissionLevel != "low" || event.AIMode != "candidate_explanation" {
		t.Fatalf("旧赛事权限应采用保守默认值: %+v", event)
	}

	for _, column := range []string{
		"search_display_allowed",
		"candidate_pool_allowed",
		"personalized_ranking_allowed",
		"strong_recommendation_eligible",
		"recommendation_permission_level",
		"ai_mode",
	} {
		var nullable int
		if err := db.Raw("SELECT [notnull] FROM pragma_table_info('competition_events') WHERE name = ?", column).Scan(&nullable).Error; err != nil {
			t.Fatal(err)
		}
		if nullable != 1 {
			t.Fatalf("列 %s 必须为 NOT NULL", column)
		}
	}
}

func TestPrepareCompetitionCatalogMigrationRejectsNilDatabase(t *testing.T) {
	if err := PrepareCompetitionCatalogMigration(nil); err == nil {
		t.Fatal("nil database 应返回错误")
	}
}

func TestPrepareCompetitionCatalogMigrationPostgres(t *testing.T) {
	dsn := os.Getenv("TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("TEST_POSTGRES_DSN 未配置，跳过真实 PostgreSQL 集成测试")
	}
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	sqlDB.SetMaxOpenConns(1)
	defer sqlDB.Close()

	schema := fmt.Sprintf("competition_catalog_migration_test_%d", time.Now().UnixNano())
	if err := db.Exec("CREATE SCHEMA " + schema).Error; err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = db.Exec("SET search_path TO public").Error
		_ = db.Exec("DROP SCHEMA IF EXISTS " + schema + " CASCADE").Error
	}()
	if err := db.Exec("SET search_path TO " + schema).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Exec(`CREATE TABLE competition_events (
		id bigserial PRIMARY KEY,
		title varchar(200) NOT NULL,
		competition_level varchar(40),
		school_recognition_status varchar(32),
		version integer DEFAULT 1,
		competition_id varchar(64)
	)`).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Exec("INSERT INTO competition_events (title, competition_level, school_recognition_status, version) VALUES (?, ?, ?, ?)",
		"旧赛事", "national", "recognized", 1).Error; err != nil {
		t.Fatal(err)
	}

	for range 2 {
		if err := PrepareCompetitionCatalogMigration(db); err != nil {
			t.Fatalf("PostgreSQL 预迁移应可重复执行: %v", err)
		}
	}
	if err := db.AutoMigrate(&CompetitionCatalogPackage{}, &CompetitionCatalogAuditLog{}, &CompetitionEvent{}); err != nil {
		t.Fatal(err)
	}
	if err := BackfillCompetitionCatalogMetadata(db); err != nil {
		t.Fatal(err)
	}

	var event CompetitionEvent
	if err := db.First(&event).Error; err != nil {
		t.Fatal(err)
	}
	if event.CompetitionID != "LEGACY-1" || !event.SearchDisplayAllowed || !event.CandidatePoolAllowed {
		t.Fatalf("PostgreSQL 旧赛事回填不完整: %+v", event)
	}
	var nullableColumns int64
	if err := db.Raw(`SELECT count(*) FROM information_schema.columns
		WHERE table_schema = current_schema()
		AND table_name = 'competition_events'
		AND column_name IN ?
		AND is_nullable = 'NO'`, []string{
		"search_display_allowed",
		"candidate_pool_allowed",
		"personalized_ranking_allowed",
		"strong_recommendation_eligible",
		"recommendation_permission_level",
		"ai_mode",
	}).Scan(&nullableColumns).Error; err != nil {
		t.Fatal(err)
	}
	if nullableColumns != 6 {
		t.Fatalf("PostgreSQL 非空目录权限列数量=%d want=6", nullableColumns)
	}
}
