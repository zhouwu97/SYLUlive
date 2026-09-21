package services

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

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
	"user_emoji_assets",
}

// TemporaryFileJanitorConfig 描述临时文件回收策略。
type TemporaryFileJanitorConfig struct {
	TTL       time.Duration
	BatchSize int
	// NotBefore 是显式配置的历史边界，早于该时间的 temporary 永不由本任务批量处理；
	// deleting 状态不受该边界影响，仍会重试已经开始的清理。
	NotBefore time.Time
	// OnlyRetryDeleting 用于尚未完成历史审计的部署：只恢复既有 deleting 状态，
	// 不触碰任何 temporary，避免漏配边界时误删历史数据。
	OnlyRetryDeleting bool
}

// TemporaryFileJanitorReport 汇总一轮有限批量清理结果。
type TemporaryFileJanitorReport struct {
	Scanned             int
	MarkedDeleting      int
	Removed             int
	RemovedBytes        int64
	RetainedReferenced  int
	RetainedRecentGrant int
	SkippedClaimed      int
	Errors              int
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

type temporaryFileJanitorResult struct {
	markedDeleting      bool
	removed             bool
	removedBytes        int64
	retainedReferenced  bool
	retainedRecentGrant bool
	skippedClaimed      bool
	err                 error
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
	query := j.db.WithContext(ctx)
	if j.config.OnlyRetryDeleting {
		query = query.Where("status = ?", models.FileStatusDeleting)
	} else if j.config.NotBefore.IsZero() {
		query = query.Where("(status = ? AND claimed_at IS NULL AND created_at < ?) OR status = ?", models.FileStatusTemporary, cutoff, models.FileStatusDeleting)
	} else {
		query = query.Where("(status = ? AND claimed_at IS NULL AND created_at < ? AND created_at >= ?) OR status = ?", models.FileStatusTemporary, cutoff, j.config.NotBefore, models.FileStatusDeleting)
	}
	if err := query.Order("id ASC").Limit(j.config.BatchSize).Find(&files).Error; err != nil {
		return report, err
	}
	report.Scanned = len(files)
	for _, file := range files {
		if err := ctx.Err(); err != nil {
			return report, err
		}
		result := j.processFile(ctx, file.ID, cutoff)
		if result.markedDeleting {
			report.MarkedDeleting++
		}
		if result.retainedReferenced {
			report.RetainedReferenced++
		}
		if result.retainedRecentGrant {
			report.RetainedRecentGrant++
		}
		if result.skippedClaimed {
			report.SkippedClaimed++
		}
		if result.removed {
			report.Removed++
			report.RemovedBytes += result.removedBytes
		}
		if result.err != nil {
			report.Errors++
			j.log("临时文件清理失败: file_id=%d error=%v", file.ID, result.err)
		}
	}
	return report, nil
}

// processFile 分成“提交 deleting 标记 → 物理删除 → 最终数据库删除”三个阶段。
// deleting 标记必须先提交，避免物理删除成功后数据库事务回滚，把记录恢复成
// temporary 并让业务误以为文件仍然可用。所有正常 claim 都会锁同一行并拒绝 deleting。
func (j *TemporaryFileJanitor) processFile(ctx context.Context, fileID uint, cutoff time.Time) (result temporaryFileJanitorResult) {
	var file models.File
	eligible := false
	markErr := j.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&file, fileID).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return nil
			}
			return err
		}

		if file.Status == models.FileStatusTemporary {
			if j.config.OnlyRetryDeleting {
				return nil
			}
			if file.ClaimedAt != nil {
				result.skippedClaimed = true
				return nil
			}
			if !file.CreatedAt.Before(cutoff) || (!j.config.NotBefore.IsZero() && file.CreatedAt.Before(j.config.NotBefore)) {
				return nil
			}
			eligible = true
		} else if file.Status == models.FileStatusDeleting {
			if file.ClaimedAt != nil {
				// 异常的 deleting+claimed 记录不能再由 janitor 删除；若物理文件
				// 仍在则恢复 active，否则保留 deleting 交给一致性巡检处理。
				if err := j.restoreClaimedDeletingFile(tx, file); err != nil {
					result.err = err
				}
				result.skippedClaimed = true
				return nil
			}
			eligible = true
		} else {
			return nil
		}

		referenced, err := hasBusinessFileReference(tx, file.ID, j.tableAvailable)
		if err != nil {
			return err
		}
		if referenced {
			result.retainedReferenced = true
			if file.Status == models.FileStatusDeleting {
				// deleting 标记提交后可能有历史业务引用才被发现，或人工修复
				// 先写入了关联表。物理文件仍存在时必须恢复 active，否则后续
				// 所有正常读取都会被永久卡在 deleting 状态。
				if err := j.restoreReferencedDeletingFile(tx, file); err != nil {
					result.err = err
				}
			}
			return nil
		}
		recentGrant, err := hasRecentUploadGrant(tx, file.ID, cutoff, j.tableAvailable)
		if err != nil {
			return err
		}
		if recentGrant {
			result.retainedRecentGrant = true
			if file.Status == models.FileStatusDeleting {
				if err := j.restoreDeletingFileToTemporary(tx, file); err != nil {
					result.err = err
				}
			}
			return nil
		}

		if file.Status == models.FileStatusTemporary {
			mark := tx.Model(&models.File{}).Where("id = ? AND status = ? AND claimed_at IS NULL", file.ID, models.FileStatusTemporary).
				Update("status", models.FileStatusDeleting)
			if mark.Error != nil {
				return mark.Error
			}
			if mark.RowsAffected != 1 {
				result.skippedClaimed = true
				return nil
			}
			result.markedDeleting = true
			file.Status = models.FileStatusDeleting
		}
		return nil
	})
	if markErr != nil {
		result.err = markErr
		return result
	}
	if file.ID == 0 || !eligible || result.retainedReferenced || result.retainedRecentGrant || result.skippedClaimed {
		return result
	}

	source, sourceErr := ResolveUploadPath(j.uploadDir, file.Path)
	if sourceErr != nil {
		result.err = fmt.Errorf("临时文件路径非法，deleting 状态已提交: %w", sourceErr)
		return result
	}
	sharedPath, sharedErr := j.hasSharedPhysicalPath(file)
	if sharedErr != nil {
		result.err = sharedErr
		return result
	}
	quarantine := temporaryFileQuarantine{source: source}
	if !sharedPath {
		var quarantineErr error
		quarantine, quarantineErr = j.quarantinePhysicalFile(file)
		if quarantineErr != nil {
			result.err = quarantineErr
			return result
		}
	}

	// 物理文件已经移入同一文件系统的 .trash 隔离目录后重新锁行复核引用。
	// 若发现业务引用，先恢复原路径再把记录恢复 active；只有最终确认无引用时
	// 才在删除数据库记录前清理 trash 文件。这样物理删除失败会回滚数据库变更，
	// 不会留下数据库已删除但隔离副本永久无人回收的垃圾。
	restoreNeeded := false
	finalErr := j.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var current models.File
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&current, file.ID).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				restoreNeeded = true
				return nil
			}
			return err
		}
		if current.Status != models.FileStatusDeleting {
			restoreNeeded = true
			return nil
		}
		referenced, err := hasBusinessFileReference(tx, current.ID, j.tableAvailable)
		if err != nil {
			return err
		}
		if referenced {
			result.retainedReferenced = true
			if quarantine.moved {
				if err := restoreTemporaryFileQuarantine(quarantine); err != nil {
					return err
				}
				if err := tx.Model(&models.File{}).Where("id = ? AND status = ?", current.ID, models.FileStatusDeleting).
					Updates(map[string]interface{}{"status": models.FileStatusActive, "claimed_at": gorm.Expr("COALESCE(claimed_at, CURRENT_TIMESTAMP)")}).Error; err != nil {
					return err
				}
			} else {
				info, statErr := os.Stat(quarantine.source)
				if errors.Is(statErr, os.ErrNotExist) {
					result.err = fmt.Errorf("deleting 文件已有业务引用但物理文件不存在: file_id=%d", current.ID)
				} else if statErr != nil {
					return statErr
				} else if info.IsDir() {
					result.err = fmt.Errorf("deleting 文件已有业务引用但物理路径是目录: file_id=%d", current.ID)
				}
			}
			return nil
		}
		recentGrant, err := hasRecentUploadGrant(tx, current.ID, cutoff, j.tableAvailable)
		if err != nil {
			return err
		}
		if recentGrant {
			result.retainedRecentGrant = true
			if quarantine.moved {
				if err := restoreTemporaryFileQuarantine(quarantine); err != nil {
					return err
				}
			} else {
				info, statErr := os.Stat(quarantine.source)
				if errors.Is(statErr, os.ErrNotExist) {
					return fmt.Errorf("deleting 文件有近期上传授权但物理文件不存在: file_id=%d", current.ID)
				}
				if statErr != nil {
					return statErr
				}
				if info.IsDir() {
					return fmt.Errorf("deleting 文件有近期上传授权但物理路径是目录: file_id=%d", current.ID)
				}
			}
			if err := tx.Model(&models.File{}).Where("id = ? AND status = ?", current.ID, models.FileStatusDeleting).
				Updates(map[string]interface{}{"status": models.FileStatusTemporary, "claimed_at": nil}).Error; err != nil {
				return err
			}
			return nil
		}
		sharedNow, err := j.hasSharedPhysicalPathTx(tx, current)
		if err != nil {
			return err
		}
		if sharedNow && quarantine.moved {
			if err := restoreTemporaryFileQuarantine(quarantine); err != nil {
				return err
			}
			quarantine.moved = false
		}
		if quarantine.moved {
			if err := os.Remove(quarantine.trash); err != nil && !errors.Is(err, os.ErrNotExist) {
				return fmt.Errorf("删除临时文件隔离副本失败，保留 deleting 状态: %w", err)
			}
			quarantine.moved = false
		}
		if err := tx.Where("file_id = ?", current.ID).Delete(&models.FileUploadGrant{}).Error; err != nil {
			return err
		}
		deleteResult := tx.Where("id = ? AND status = ?", current.ID, models.FileStatusDeleting).Delete(&models.File{})
		if deleteResult.Error != nil {
			return deleteResult.Error
		}
		if deleteResult.RowsAffected == 1 {
			result.removed = true
			result.removedBytes = current.Size
		}
		return nil
	})
	if finalErr != nil {
		if quarantine.moved {
			restoreNeeded = true
		}
		result.err = finalErr
	}
	if restoreNeeded {
		if err := restoreTemporaryFileQuarantine(quarantine); err != nil && result.err == nil {
			result.err = err
		}
	}
	return result
}

// restoreClaimedDeletingFile 处理已经 claim 但异常停留在 deleting 的记录。
// 只有确认原文件仍是普通文件时才恢复状态，路径异常或文件缺失都留给巡检处理。
func (j *TemporaryFileJanitor) restoreClaimedDeletingFile(tx *gorm.DB, file models.File) error {
	path, err := ResolveUploadPath(j.uploadDir, file.Path)
	if err != nil {
		return fmt.Errorf("deleting+claimed 文件路径非法: %w", err)
	}
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("deleting+claimed 文件物理文件不存在: file_id=%d", file.ID)
	}
	if err != nil {
		return err
	}
	if info.IsDir() {
		return fmt.Errorf("deleting+claimed 文件物理路径是目录: file_id=%d", file.ID)
	}
	return tx.Model(&models.File{}).Where("id = ? AND status = ?", file.ID, models.FileStatusDeleting).
		Update("status", models.FileStatusActive).Error
}

// restoreReferencedDeletingFile 把已发现业务引用且物理文件完整的 deleting 记录
// 恢复为 active。调用方已持有文件行锁，状态更新与引用判断处于同一事务。
func (j *TemporaryFileJanitor) restoreReferencedDeletingFile(tx *gorm.DB, file models.File) error {
	path, err := ResolveUploadPath(j.uploadDir, file.Path)
	if err != nil {
		return fmt.Errorf("deleting 文件已有业务引用但路径非法: %w", err)
	}
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("deleting 文件已有业务引用但物理文件不存在: file_id=%d", file.ID)
	}
	if err != nil {
		return err
	}
	if info.IsDir() {
		return fmt.Errorf("deleting 文件已有业务引用但物理路径是目录: file_id=%d", file.ID)
	}
	return tx.Model(&models.File{}).Where("id = ? AND status = ?", file.ID, models.FileStatusDeleting).
		Updates(map[string]interface{}{
			"status":     models.FileStatusActive,
			"claimed_at": gorm.Expr("COALESCE(claimed_at, CURRENT_TIMESTAMP)"),
		}).Error
}

func (j *TemporaryFileJanitor) restoreDeletingFileToTemporary(tx *gorm.DB, file models.File) error {
	path, err := ResolveUploadPath(j.uploadDir, file.Path)
	if err != nil {
		return fmt.Errorf("deleting 文件有近期上传授权但路径非法: %w", err)
	}
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("deleting 文件有近期上传授权但物理文件不存在: file_id=%d", file.ID)
	}
	if err != nil {
		return err
	}
	if info.IsDir() {
		return fmt.Errorf("deleting 文件有近期上传授权但物理路径是目录: file_id=%d", file.ID)
	}
	return tx.Model(&models.File{}).Where("id = ? AND status = ?", file.ID, models.FileStatusDeleting).
		Updates(map[string]interface{}{"status": models.FileStatusTemporary, "claimed_at": nil}).Error
}

type temporaryFileQuarantine struct {
	source string
	trash  string
	moved  bool
}

func (j *TemporaryFileJanitor) quarantinePhysicalFile(file models.File) (temporaryFileQuarantine, error) {
	var quarantine temporaryFileQuarantine
	source, err := ResolveUploadPath(j.uploadDir, file.Path)
	if err != nil {
		return quarantine, fmt.Errorf("临时文件路径非法，deleting 状态已提交: %w", err)
	}
	quarantine.source = source
	trashDir := filepath.Join(j.uploadDir, ".trash", "upload-janitor")
	quarantine.trash = filepath.Join(trashDir, fmt.Sprintf("%d%s", file.ID, filepath.Ext(source)))
	trashInfo, trashErr := os.Stat(quarantine.trash)
	sourceInfo, sourceErr := os.Stat(source)
	if trashErr == nil && sourceErr == nil {
		return quarantine, fmt.Errorf("临时文件源路径和隔离路径同时存在: file_id=%d", file.ID)
	}
	if trashErr != nil && !errors.Is(trashErr, os.ErrNotExist) {
		return quarantine, fmt.Errorf("检查临时文件隔离路径失败: %w", trashErr)
	}
	if sourceErr != nil && !errors.Is(sourceErr, os.ErrNotExist) {
		return quarantine, fmt.Errorf("检查临时文件物理状态失败: %w", sourceErr)
	}
	if trashErr == nil {
		if trashInfo.IsDir() {
			return quarantine, fmt.Errorf("临时文件隔离路径指向目录: file_id=%d", file.ID)
		}
		quarantine.moved = true
		return quarantine, nil
	}
	if sourceErr != nil {
		return quarantine, nil
	}
	if sourceInfo.IsDir() {
		return quarantine, fmt.Errorf("临时文件路径指向目录，deleting 状态已提交: file_id=%d", file.ID)
	}
	if err := os.MkdirAll(trashDir, 0755); err != nil {
		return quarantine, fmt.Errorf("创建临时文件隔离目录失败: %w", err)
	}
	if err := os.Rename(source, quarantine.trash); err != nil {
		return quarantine, fmt.Errorf("隔离临时文件失败，deleting 状态已提交: %w", err)
	}
	quarantine.moved = true
	return quarantine, nil
}

func restoreTemporaryFileQuarantine(quarantine temporaryFileQuarantine) error {
	if !quarantine.moved {
		return nil
	}
	if _, err := os.Stat(quarantine.trash); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	if _, err := os.Stat(quarantine.source); err == nil {
		return os.Remove(quarantine.trash)
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(quarantine.source), 0755); err != nil {
		return err
	}
	return os.Rename(quarantine.trash, quarantine.source)
}

func (j *TemporaryFileJanitor) hasSharedPhysicalPath(file models.File) (bool, error) {
	var shared bool
	err := j.db.Transaction(func(tx *gorm.DB) error {
		var err error
		shared, err = j.hasSharedPhysicalPathTx(tx, file)
		return err
	})
	return shared, err
}

func (j *TemporaryFileJanitor) hasSharedPhysicalPathTx(tx *gorm.DB, file models.File) (bool, error) {
	if _, err := ResolveUploadPath(j.uploadDir, file.Path); err != nil {
		return false, err
	}
	// files.path 是业务层约定的 uploads 相对 URL，正常情况下只存在
	// /uploads/foo 与 uploads/foo 两种历史形态。直接按候选值查询，避免
	// 每处理一条文件都把整张 files 表加载到内存并形成 O(batch×N) 扫描。
	candidates := uploadReferenceCandidates(file.Path)
	if len(candidates) == 0 {
		return false, ErrInvalidImageFileReference
	}
	var count int64
	if err := tx.Model(&models.File{}).Where("id <> ? AND path IN ?", file.ID, candidates).Limit(1).Count(&count).Error; err != nil {
		return false, err
	}
	return count > 0, nil
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

// hasRecentUploadGrant 只把近期授权当作临时保留信号；过期 grant 不能永久阻止
// 清理，否则失败上传会重新形成无法回收的历史垃圾。
func hasRecentUploadGrant(db *gorm.DB, fileID uint, cutoff time.Time, tableAvailable func(string) bool) (bool, error) {
	if tableAvailable != nil && !tableAvailable("file_upload_grants") {
		return false, nil
	}
	var count int64
	if err := db.Model(&models.FileUploadGrant{}).
		Where("file_id = ? AND created_at >= ?", fileID, cutoff).
		Limit(1).Count(&count).Error; err != nil {
		return false, err
	}
	return count > 0, nil
}
