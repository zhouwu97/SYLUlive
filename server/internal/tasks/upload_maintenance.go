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
// janitor 启动时立即执行一次，之后按小时级间隔运行；巡检只报告异常，不做删除。
func StartUploadMaintenanceCron(ctx context.Context, db *gorm.DB, uploadDir string, ttl, janitorInterval time.Duration, batchSize int, consistencyInterval time.Duration) *UploadMaintenanceCron {
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

	// 首次启用只处理启动之后产生的临时文件，给历史 temporary 留出人工对账窗口。
	// 已进入 deleting 的记录仍会被重试，避免中断清理任务留下半成品。
	janitor := services.NewTemporaryFileJanitor(db, uploadDir, services.TemporaryFileJanitorConfig{
		TTL:       ttl,
		BatchSize: batchSize,
		NotBefore: time.Now(),
	})
	scanner := services.NewStorageConsistencyScanner(db, uploadDir)
	cron.wg.Add(2)
	go func() {
		defer cron.wg.Done()
		run := func() {
			report, err := janitor.Run(ctx)
			if err != nil {
				log.Printf("上传临时文件清理失败: %v", err)
				return
			}
			if report.Scanned > 0 || report.Errors > 0 {
				log.Printf("上传临时文件清理完成: scanned=%d marked=%d removed=%d removed_bytes=%d retained_referenced=%d errors=%d", report.Scanned, report.MarkedDeleting, report.Removed, report.RemovedBytes, report.RetainedReferenced, report.Errors)
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
	go func() {
		defer cron.wg.Done()
		run := func() {
			report, err := scanner.Run(ctx)
			if err != nil {
				log.Printf("上传存储一致性巡检失败: %v", err)
				return
			}
			log.Printf("上传存储一致性巡检完成: db_files=%d physical_files=%d missing=%d orphan=%d temporary_referenced=%d", report.DBFiles, report.PhysicalFiles, report.MissingPhysical, report.OrphanPhysical, report.TemporaryReferenced)
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
	log.Printf("上传临时文件保护后台任务已启动: ttl=%s janitor_interval=%s batch=%d consistency_interval=%s", ttl, janitorInterval, batchSize, consistencyInterval)
	return cron
}
