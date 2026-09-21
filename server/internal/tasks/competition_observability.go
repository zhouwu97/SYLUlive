package tasks

import (
	"context"
	"log"
	"sync"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

const competitionObservabilityCleanupInterval = 24 * time.Hour

// CompetitionObservabilityCron 负责竞赛埋点和排序追踪的生命周期维护。
type CompetitionObservabilityCron struct {
	wg sync.WaitGroup
}

// Wait 等待竞赛观测清理任务退出。
func (c *CompetitionObservabilityCron) Wait() {
	if c != nil {
		c.wg.Wait()
	}
}

// StartCompetitionObservabilityCron 启动观测明细清理，启动时先执行一次，之后每日执行。
func StartCompetitionObservabilityCron(ctx context.Context, db *gorm.DB) *CompetitionObservabilityCron {
	cron := &CompetitionObservabilityCron{}
	if db == nil {
		return cron
	}
	cron.wg.Add(1)
	go func() {
		defer cron.wg.Done()
		cleanup := func() {
			signals, traces, err := models.CleanupCompetitionObservabilityData(
				db, time.Now().UTC(), models.CompetitionCandidateSignalRetention,
				models.CompetitionRankTraceRetention, 1000,
			)
			if err != nil {
				log.Printf("竞赛推荐观测清理失败: %v", err)
				return
			}
			if signals > 0 || traces > 0 {
				log.Printf("竞赛推荐观测清理完成: signals=%d rank_traces=%d", signals, traces)
			}
		}
		cleanup()
		ticker := time.NewTicker(competitionObservabilityCleanupInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				cleanup()
			}
		}
	}()
	log.Println("竞赛推荐观测清理后台任务已启动")
	return cron
}
