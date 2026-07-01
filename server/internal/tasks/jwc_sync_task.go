package tasks

import (
	"context"
	"log"
	"sync"
	"time"

	"shenliyuan/internal/config"
	"shenliyuan/internal/services"
)

// StartCampusSyncTask 启动校园资讯定时同步任务（支持多来源）。
// 单进程 mutex 防止重叠运行。如需多实例部署，需替换为数据库锁。
func StartCampusSyncTask(ctx context.Context, svcs []*services.CampusSyncService, cfg *config.Config) {
	var mu sync.Mutex

	interval := time.Duration(cfg.JWCSyncIntervalMinutes) * time.Minute

	log.Printf("[CAMPUS_TASK] starting sync task (%d sources, interval=%v)", len(svcs), interval)

	// 启动后延迟 30s 执行首次同步
	time.AfterFunc(30*time.Second, func() {
		for _, svc := range svcs {
			runSync(ctx, &mu, svc, false)
		}
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
			for _, svc := range svcs {
				runSync(ctx, &mu, svc, false)
			}
		case <-reconcileTicker.C:
			for _, svc := range svcs {
				if svc.ShouldReconcile() {
					log.Printf("[CAMPUS_TASK] running daily reconcile")
					runSync(ctx, &mu, svc, true)
				}
			}
		case <-ctx.Done():
			log.Println("[CAMPUS_TASK] stopping sync task")
			return
		}
	}
}

func runSync(ctx context.Context, mu *sync.Mutex, svc *services.CampusSyncService, reconcile bool) {
	if !mu.TryLock() {
		log.Println("[CAMPUS_TASK] previous sync still running, skipping")
		return
	}
	// Mutex held until sync fully completes or times out — prevents overlap
	defer mu.Unlock()

	// 单次同步超时 90s
	syncCtx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()

	// 直接调用，超时通过 Context 传播到 HTTP 层真正取消请求
	result := svc.Sync(syncCtx, reconcile, 3) // max_pages=3

	if result.Error != nil {
		log.Printf("[CAMPUS_TASK] sync failed: %v", result.Error)
	} else {
		log.Printf("[CAMPUS_TASK] sync ok (added=%d updated=%d skipped=%d bootstrap=%v)",
			result.Added, result.Updated, result.Skipped, result.IsBootstrap)
	}
}
