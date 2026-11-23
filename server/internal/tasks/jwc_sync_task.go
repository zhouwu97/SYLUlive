package tasks

import (
	"context"
	"log"
	"time"

	"shenliyuan/internal/config"
	"shenliyuan/internal/services"
)

// StartCampusSyncTask 启动校园资讯定时同步任务（支持多来源）。
func StartCampusSyncTask(ctx context.Context, svcs []*services.CampusSyncService, cfg *config.Config) {
	interval := time.Duration(cfg.JWCSyncIntervalMinutes) * time.Minute
	first := time.NewTimer(30 * time.Second)
	defer first.Stop()
	regular := time.NewTicker(interval)
	defer regular.Stop()
	reconcile := time.NewTicker(time.Hour)
	defer reconcile.Stop()
	for {
		window := interval
		daily := false
		select {
		case <-ctx.Done():
			return
		case <-first.C:
		case <-regular.C:
		case <-reconcile.C:
			window = time.Hour
			daily = true
		}
		for _, svc := range svcs {
			result := svc.SyncScheduled(ctx, window, daily)
			if result == nil {
				continue
			}
			if result.Error != nil {
				log.Printf("[CAMPUS_TASK] sync failed: %v", result.Error)
			} else {
				log.Printf("[CAMPUS_TASK] sync ok (added=%d updated=%d skipped=%d bootstrap=%v)", result.Added, result.Updated, result.Skipped, result.IsBootstrap)
			}
		}
	}
}
