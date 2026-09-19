package services

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// temporaryFileReferenceTables 是所有直接以 file_id 引用公共 files 表的业务表。
// 表不存在时跳过，便于旧部署和轻量级测试数据库平滑启用清理任务。
var temporaryFileReferenceTables = []string{
	"messages",
	"post_images",
	"reply_images",
	"feedback_attachments",
	"image_variants",
	"canteen_dish_photos",
	"competition_award_evidences",
	"competition_award_evidence_access_logs",
	"user_emoji_assets",
}

// TemporaryFileJanitorConfig 描述临时文件回收策略。
type TemporaryFileJanitorConfig struct {
	TTL       time.Duration
	BatchSize int
}

// TemporaryFileJanitorReport 汇总一轮有限批量清理结果。
type TemporaryFileJanitorReport struct {
	Scanned            int
	MarkedDeleting     int
	Removed            int
	RemovedBytes       int64
	RetainedReferenced int
	SkippedClaimed     int
	Errors             int
}

// TemporaryFileJanitor 按“标记 deleting → 删除磁盘文件 → 删除数据库记录”执行清理。
type TemporaryFileJanitor struct {
	db        *gorm.DB
	uploadDir string
	config    TemporaryFileJanitorConfig
	now       func() time.Time
	log       func(string, ...interface{})
	cacheMu   sync.Mutex
	tableSeen map[string]bool
}

// NewTemporaryFileJanitor 创建临时文件清理器。
func NewTemporaryFileJanitor(db *gorm.DB, uploadDir string, config TemporaryFileJanitorConfig) *TemporaryFileJanitor {
	if config.TTL <= 0 {
		config.TTL = 6 * time.Hour
	}
	if config.BatchSize <= 0 {
		config.BatchSize = 200
	}
	return &TemporaryFileJanitor{
		db:        db,
		uploadDir: uploadDir,
		config:    config,
		now:       time.Now,
		log:       log.Printf,
		tableSeen: make(map[string]bool),
	}
}

// SetNow 为时间窗口测试注入时钟。
func (j *TemporaryFileJanitor) SetNow(now func() time.Time) {
	if j != nil && now != nil {
		j.now = now
	}
}

// SetLogger 允许任务层接入统一日志；nil 恢复默认日志。
func (j *TemporaryFileJanitor) SetLogger(logger func(string, ...interface{})) {
	if j == nil {
		return
	}
	if logger == nil {
		j.log = log.Printf
		return
	}
	j.log = logger
}

// Run 执行一轮有限批量回收。业务引用检查和状态更新均以数据库当前状态为准，
// 状态更新带条件，避免与 claim 事务竞争时误删新产生的业务引用。
func (j *TemporaryFileJanitor) Run(ctx context.Context) (TemporaryFileJanitorReport, error) {
	var report TemporaryFileJanitorReport
	if j == nil || j.db == nil {
		return report, fmt.Errorf("临时文件清理器未初始化")
	}
	if err := ctx.Err(); err != nil {
		return report, err
	}
	cutoff := j.now().Add(-j.config.TTL)
	var files []models.File
	if err := j.db.WithContext(ctx).
		Where("(status = ? AND claimed_at IS NULL AND created_at < ?) OR status = ?", models.FileStatusTemporary, cutoff, models.FileStatusDeleting).
		Order("id ASC").Limit(j.config.BatchSize).Find(&files).Error; err != nil {
		return report, err
	}
	report.Scanned = len(files)
	for _, file := range files {
		if err := ctx.Err(); err != nil {
			return report, err
		}
		if file.Status == models.FileStatusTemporary {
			referenced, err := hasBusinessFileReference(j.db, file.ID, j.tableAvailable)
			if err != nil {
				report.Errors++
				j.log("临时文件引用检查失败: file_id=%d error=%v", file.ID, err)
				continue
			}
			if referenced {
				report.RetainedReferenced++
				continue
			}
			result := j.db.WithContext(ctx).Model(&models.File{}).
				Where("id = ? AND status = ? AND claimed_at IS NULL", file.ID, models.FileStatusTemporary).
				Update("status", models.FileStatusDeleting)
			if result.Error != nil {
				report.Errors++
				j.log("临时文件标记删除失败: file_id=%d error=%v", file.ID, result.Error)
				continue
			}
			if result.RowsAffected == 0 {
				report.SkippedClaimed++
				continue
			}
			report.MarkedDeleting++
		}

		path, err := ResolveUploadPath(j.uploadDir, file.Path)
		if err != nil {
			report.Errors++
			j.log("临时文件路径非法，保留 deleting 状态等待人工修复: file_id=%d path=%q error=%v", file.ID, file.Path, err)
			continue
		}
		info, statErr := os.Stat(path)
		if statErr != nil && !errors.Is(statErr, os.ErrNotExist) {
			report.Errors++
			j.log("临时文件物理状态检查失败: file_id=%d path=%q error=%v", file.ID, path, statErr)
			continue
		}
		if statErr == nil {
			if info.IsDir() {
				report.Errors++
				j.log("临时文件路径指向目录，拒绝删除: file_id=%d path=%q", file.ID, path)
				continue
			}
			if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
				report.Errors++
				j.log("删除临时文件失败，保留 deleting 状态: file_id=%d path=%q error=%v", file.ID, path, err)
				continue
			}
		}

		deleteErr := j.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
			if err := tx.Where("file_id = ?", file.ID).Delete(&models.FileUploadGrant{}).Error; err != nil {
				return err
			}
			return tx.Where("id = ? AND status = ?", file.ID, models.FileStatusDeleting).Delete(&models.File{}).Error
		})
		if deleteErr != nil {
			report.Errors++
			j.log("删除临时文件数据库记录失败，保留 deleting 状态: file_id=%d error=%v", file.ID, deleteErr)
			continue
		}
		report.Removed++
		report.RemovedBytes += file.Size
	}
	return report, nil
}

func (j *TemporaryFileJanitor) tableAvailable(table string) bool {
	j.cacheMu.Lock()
	defer j.cacheMu.Unlock()
	if value, ok := j.tableSeen[table]; ok {
		return value
	}
	value := j.db.Migrator().HasTable(table)
	j.tableSeen[table] = value
	return value
}

// hasBusinessFileReference 只检查明确的 file_id 关系，不把上传授权 grant 当作业务引用。
// 该函数供清理器和一致性巡检共同使用，避免两套引用白名单逐渐漂移。
func hasBusinessFileReference(db *gorm.DB, fileID uint, tableAvailable func(string) bool) (bool, error) {
	for _, table := range temporaryFileReferenceTables {
		if tableAvailable != nil && !tableAvailable(table) {
			continue
		}
		var count int64
		if err := db.Table(table).Where("file_id = ?", fileID).Limit(1).Count(&count).Error; err != nil {
			return false, err
		}
		if count > 0 {
			return true, nil
		}
	}
	return false, nil
}
