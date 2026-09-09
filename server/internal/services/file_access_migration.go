package services

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
)

const FileAccessScopeMigrationVersion = "20260909_01_file_access_scope_reconcile"

// 同一批次复用表探测结果；业务规则仍由运行时回收和历史迁移共同调用。
type publicReferenceChecker struct {
	db     *gorm.DB
	tables map[string]bool
}

func newPublicReferenceChecker(db *gorm.DB) *publicReferenceChecker {
	return &publicReferenceChecker{db: db, tables: make(map[string]bool)}
}

func (c *publicReferenceChecker) hasTable(table string) bool {
	if exists, ok := c.tables[table]; ok {
		return exists
	}
	exists := c.db.Migrator().HasTable(table)
	c.tables[table] = exists
	return exists
}

func (c *publicReferenceChecker) hasPublicPathReference(filePath string) (bool, error) {
	path, valid := normalizeUploadReference(filePath)
	if !valid {
		return false, nil
	}
	// LIKE 只缩小候选范围；最终按完整路径核对，避免文件名前缀、查询参数
	// 或 JSON 中的其他字符串被误认为该文件的公开引用。
	candidate := "%" + strings.TrimPrefix(path, "/") + "%"
	check := func(query *gorm.DB, column string, list bool) (bool, error) {
		var values []string
		if err := query.Where(column+" LIKE ?", candidate).Pluck(column, &values).Error; err != nil {
			return false, err
		}
		for _, value := range values {
			references := []string{value}
			if list {
				if err := json.Unmarshal([]byte(value), &references); err != nil {
					return false, fmt.Errorf("解析公开图片引用 %s: %w", column, err)
				}
			}
			for _, reference := range references {
				if normalized, ok := normalizeUploadReference(reference); ok && normalized == path {
					return true, nil
				}
			}
		}
		return false, nil
	}
	if c.hasTable("canteens") {
		if found, err := check(c.db.Table("canteens").Where("verified = ?", true), "image", false); found || err != nil {
			return found, err
		}
		for _, table := range []string{"canteen_ratings", "canteen_review_events"} {
			if !c.hasTable(table) {
				continue
			}
			query := c.db.Table(table+" AS r").Joins("JOIN canteens c ON c.id = r.canteen_id AND c.verified = ?", true)
			if table == "canteen_ratings" {
				query = query.Where("r.status = ? OR r.status IS NULL OR r.status = ''", models.ReviewEventStatusActive)
			} else {
				query = query.Where("r.status = ?", models.ReviewEventStatusActive)
			}
			if found, err := check(query, "r.images", true); found || err != nil {
				return found, err
			}
		}
	}
	for _, source := range []struct {
		table   string
		columns []string
	}{
		{"users", []string{"avatar", "background"}},
		{"water_sections", []string{"avatar_url", "cover_url", "cover_portrait_url", "cover_landscape_url", "cover_square_url"}},
	} {
		if !c.hasTable(source.table) {
			continue
		}
		for _, column := range source.columns {
			if found, err := check(c.db.Table(source.table), column, false); found || err != nil {
				return found, err
			}
		}
	}
	return false, nil
}

// MigrateFileAccessScopes 只修复一次历史权限；版本记录与文件更新同事务提交，
// 失败时整体回滚。PostgreSQL 事务锁阻止多个实例同时执行同一迁移。
func MigrateFileAccessScopes(db *gorm.DB) error {
	if err := db.AutoMigrate(&models.AppSchemaMigration{}); err != nil {
		return err
	}
	return db.Transaction(func(tx *gorm.DB) error {
		if tx.Dialector.Name() == "postgres" {
			if err := tx.Exec("SELECT pg_advisory_xact_lock(hashtext(?))", FileAccessScopeMigrationVersion).Error; err != nil {
				return err
			}
		}
		var applied int64
		if err := tx.Model(&models.AppSchemaMigration{}).Where("version = ?", FileAccessScopeMigrationVersion).Count(&applied).Error; err != nil || applied > 0 {
			return err
		}
		checker := newPublicReferenceChecker(tx)
		// 保留旧迁移对私信文件生命周期的修复，不因此赋予公开权限。
		if checker.hasTable("messages") {
			if err := tx.Exec(`UPDATE files SET status = 'active', claimed_at = COALESCE(claimed_at, CURRENT_TIMESTAMP)
WHERE EXISTS (SELECT 1 FROM messages WHERE messages.file_id = files.id)`).Error; err != nil {
				return err
			}
		}
		var cursor uint
		for {
			var files []models.File
			if err := tx.Select("id", "path", "status", "access_scope").Where("id > ?", cursor).Order("id").Limit(200).Find(&files).Error; err != nil {
				return err
			}
			if len(files) == 0 {
				break
			}
			for _, file := range files {
				scope := models.FileAccessPrivate
				if file.Status == "active" || file.Status == "temporary" {
					public, err := checker.hasActivePublicReferences(file.ID, file.Path)
					if err != nil {
						return fmt.Errorf("核对文件 %d 公开引用: %w", file.ID, err)
					}
					if public {
						scope = models.FileAccessPublic
					}
				}
				updates := map[string]interface{}{}
				if scope != file.AccessScope {
					updates["access_scope"] = scope
				}
				// 历史公开引用可能早于文件认领机制，补齐 active，避免被临时文件清理误删。
				if scope == models.FileAccessPublic && file.Status == "temporary" {
					updates["status"] = "active"
					updates["claimed_at"] = gorm.Expr("COALESCE(claimed_at, CURRENT_TIMESTAMP)")
				}
				if len(updates) > 0 {
					if err := tx.Model(&models.File{}).Where("id = ?", file.ID).Updates(updates).Error; err != nil {
						return err
					}
				}
			}
			cursor = files[len(files)-1].ID
		}
		return tx.Create(&models.AppSchemaMigration{Version: FileAccessScopeMigrationVersion, AppliedAt: time.Now()}).Error
	})
}
