package tasks

import (
	"context"
	"log"
	"sync"
	"time"
)

// feedMetricsAggregator 每日 Feed 指标聚合接口（FEED-4）。
type feedMetricsAggregator interface {
	AggregateAndCleanup(ctx context.Context, day time.Time, ttl time.Duration) (int64, error)
}

const (
	feedMetricsAggregateInterval = 24 * time.Hour
	feedMetricsTTL               = 30 * 24 * time.Hour // feed_impressions 明细保留 30 天
)

// FeedMetricsCron 持有 Feed 指标每日聚合任务的退出同步状态。
type FeedMetricsCron struct {
	wg sync.WaitGroup
}

// Wait 等待聚合任务在 context 取消后退出。
func (c *FeedMetricsCron) Wait() {
	if c != nil {
		c.wg.Wait()
	}
}

// StartFeedMetricsCron 启动每日 Feed 指标聚合：
// 启动时立即聚合昨天，之后每 24 小时聚合一次，同时清理 30 天前曝光明细。
func StartFeedMetricsCron(ctx context.Context, agg feedMetricsAggregator) *FeedMetricsCron {
	cron := &FeedMetricsCron{}
	cron.wg.Add(1)
	go func() {
		defer cron.wg.Done()
		run := func() {
			day := time.Now().Add(-24 * time.Hour) // 聚合昨天
			removed, err := agg.AggregateAndCleanup(ctx, day, feedMetricsTTL)
			if err != nil {
				log.Printf("Feed 指标聚合失败: %v", err)
				return
			}
			log.Printf("Feed 指标聚合完成: day=%s removed_impressions=%d", day.Format("2006-01-02"), removed)
		}
		run()
		ticker := time.NewTicker(feedMetricsAggregateInterval)
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
	log.Println("Feed 指标每日聚合任务已启动")
	return cron
}
