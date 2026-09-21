package tasks

import (
	"context"
	"log"
	"sync"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/services"
)

// UploadMaintenanceCron 负责临时上传回收和只读一致性巡检。
type UploadMaintenanceCron struct {
	wg sync.WaitGroup
}

// Wait 等待上传存储后台任务在 context 取消后退出。
func (c *UploadMaintenanceCron) Wait() {
	if c != nil {
		c.wg.Wait()
	}
}

// StartUploadMaintenanceCron 启动临时文件 janitor 和存储一致性巡检。
// 未配置历史边界时 janitor 只重试已进入 deleting 的记录；巡检始终只报告异常。
func StartUploadMaintenanceCron(ctx context.Context, db *gorm.DB, uploadDir string, ttl, janitorInterval time.Duration, batchSize int, cleanupNotBefore time.Time, consistencyInterval time.Duration) *UploadMaintenanceCron {
	cron := &UploadMaintenanceCron{}
	if db == nil {
		return cron
	}
	if ttl <= 0 {
		ttl = 6 * time.Hour
	}
	if janitorInterval <= 0 {
		janitorInterval = time.Hour
	}
	if batchSize <= 0 {
		batchSize = 200
	}
	if consistencyInterval <= 0 {
		consistencyInterval = 6 * time.Hour
	}

	scanner := services.NewStorageConsistencyScanner(db, uploadDir)
	janitorConfig := services.TemporaryFileJanitorConfig{
		TTL:       ttl,
		BatchSize: batchSize,
		NotBefore: cleanupNotBefore,
	}
	if cleanupNotBefore.IsZero() {
		// 历史 temporary 尚未明确审计边界时仍重试已经进入 deleting 的记录，
		// 但不处理任何 temporary；不能用每次启动时间代替持久配置。
		janitorConfig.OnlyRetryDeleting = true
		log.Printf("上传临时文件自动清理未启用: 未配置 UPLOAD_TEMPORARY_CLEANUP_NOT_BEFORE，仅重试 deleting 状态")
	}
	janitor := services.NewTemporaryFileJanitor(db, uploadDir, janitorConfig)
	cron.wg.Add(1)
	go func() {
		defer cron.wg.Done()
		run := func() {
			report, err := janitor.Run(ctx)
			if err != nil {
				log.Printf("上传临时文件清理失败: %v", err)
				return
			}
			if report.Scanned > 0 || report.Errors > 0 {
				log.Printf("上传临时文件清理完成: scanned=%d marked=%d removed=%d removed_bytes=%d retained_referenced=%d retained_recent_grant=%d errors=%d", report.Scanned, report.MarkedDeleting, report.Removed, report.RemovedBytes, report.RetainedReferenced, report.RetainedRecentGrant, report.Errors)
			}
		}
		run()
		ticker := time.NewTicker(janitorInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				run()
			}
		}
	}()
	cron.wg.Add(1)
	go func() {
		defer cron.wg.Done()
		run := func() {
			report, err := scanner.Run(ctx)
			if err != nil {
				log.Printf("上传存储一致性巡检失败: %v", err)
				return
			}
			log.Printf("上传存储一致性巡检完成: db_files=%d physical_files=%d missing=%d orphan=%d temporary_referenced=%d temporary_claimed=%d", report.DBFiles, report.PhysicalFiles, report.MissingPhysical, report.OrphanPhysical, report.TemporaryReferenced, report.TemporaryClaimed)
		}
		run()
		ticker := time.NewTicker(consistencyInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				run()
			}
		}
	}()
	log.Printf("上传存储后台任务已启动: cleanup_not_before=%s ttl=%s janitor_interval=%s batch=%d consistency_interval=%s", cleanupNotBefore.Format(time.RFC3339), ttl, janitorInterval, batchSize, consistencyInterval)
	return cron
}
