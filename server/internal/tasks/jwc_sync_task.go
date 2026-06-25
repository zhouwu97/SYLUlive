package tasks

import (
	"context"
	"log"
	"sync"
	"time"

	"shenliyuan/internal/config"
	"shenliyuan/internal/services"
)

// StartJWCSyncTask 启动校园资讯定时同步任务。
// 单进程 mutex 防止重叠运行。如需多实例部署，需替换为数据库锁。
func StartJWCSyncTask(ctx context.Context, svc *services.JWCSyncService, cfg *config.Config) {
	var mu sync.Mutex

	interval := time.Duration(cfg.JWCSyncIntervalMinutes) * time.Minute

	log.Printf("[JWC_TASK] starting sync task (interval=%v)", interval)

	// 启动后延迟 30s 执行首次同步
	time.AfterFunc(30*time.Second, func() {
		runSync(ctx, &mu, svc, false)
	})

	// 定期同步
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	// 每日 reconcile 检查（每 1 小时检查一次是否超过 24h）
	reconcileTicker := time.NewTicker(1 * time.Hour)
	defer reconcileTicker.Stop()

	for {
		select {
		case <-ticker.C:
			runSync(ctx, &mu, svc, false)
		case <-reconcileTicker.C:
			if svc.ShouldReconcile() {
				log.Println("[JWC_TASK] running daily reconcile")
				runSync(ctx, &mu, svc, true)
			}
		case <-ctx.Done():
			log.Println("[JWC_TASK] stopping sync task")
			return
		}
	}
}

func runSync(ctx context.Context, mu *sync.Mutex, svc *services.JWCSyncService, reconcile bool) {
	if !mu.TryLock() {
		log.Println("[JWC_TASK] previous sync still running, skipping")
		return
	}
	defer mu.Unlock()

	// 单次同步超时 90s
	syncCtx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()

	done := make(chan *services.SyncResult, 1)
	go func() {
		result := svc.Sync(reconcile, 3) // max_pages=3
		done <- result
	}()

	select {
	case result := <-done:
		if result.Error != nil {
			log.Printf("[JWC_TASK] sync failed: %v", result.Error)
		} else {
			log.Printf("[JWC_TASK] sync ok (added=%d updated=%d skipped=%d bootstrap=%v)",
				result.Added, result.Updated, result.Skipped, result.IsBootstrap)
		}
	case <-syncCtx.Done():
		log.Println("[JWC_TASK] sync timed out (90s)")
	}
}
