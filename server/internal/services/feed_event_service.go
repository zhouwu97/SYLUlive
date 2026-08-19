package services

import (
	"context"
	"errors"
	"fmt"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

// ErrInvalidFeedEvent 事件参数校验失败（handler 据此返回 400）。
var ErrInvalidFeedEvent = errors.New("无效的 Feed 事件参数")

// FeedEventService 记录首页 Feed 行为事件（曝光 / 打开 / 停留）。
//
// 幂等语义（FEED-2）：
//   - impression：upsert，visible_ms 取最大；
//   - open：opened_at 取最早非空值，重复发送不增加数量；
//   - dwell：dwell_ms 取最大，禁止累加，防止重试翻倍。
//
// 采用 事务 + 读改写 实现而不是一句方言化 SQL：
// 保证 PostgreSQL / SQLite（单测）两端一致可测；并发下偶发丢失一次
// 分析字段更新对推荐指标无正确性影响。
type FeedEventService struct {
	db *gorm.DB
}

func NewFeedEventService(db *gorm.DB) *FeedEventService {
	return &FeedEventService{db: db}
}

// FeedEvent 单条事件载荷（handler 解析后传入）。
type FeedEvent struct {
	Type      models.FeedEventType
	PostID    uint
	Position  int
	VisibleMS int
	DwellMS   int
}

// RecordEvents 批量记录事件，全部幂等。
// 同一请求内相同唯一键的多个事件先合并再落库。
func (s *FeedEventService) RecordEvents(userID uint, feedSessionID, feedKind, algorithmVersion string, events []FeedEvent) error {
	if userID == 0 {
		return fmt.Errorf("%w: user_id 不能为 0", ErrInvalidFeedEvent)
	}
	if feedSessionID == "" {
		return fmt.Errorf("%w: feed_session_id 不能为空", ErrInvalidFeedEvent)
	}
	if !models.IsValidFeedKind(feedKind) {
		return fmt.Errorf("%w: 无效的 feed_kind", ErrInvalidFeedEvent)
	}
	if len(events) == 0 {
		return nil
	}

	// 同一唯一键（user+session+kind+post）内的多个事件合并。
	merged := map[uint]*models.FeedImpression{}
	var order []uint
	for _, ev := range events {
		if ev.PostID == 0 {
			continue
		}
		row, ok := merged[ev.PostID]
		if !ok {
			row = &models.FeedImpression{
				UserID:           userID,
				PostID:           ev.PostID,
				FeedSessionID:    feedSessionID,
				FeedKind:         feedKind,
				AlgorithmVersion: algorithmVersion,
			}
			merged[ev.PostID] = row
			order = append(order, ev.PostID)
		}
		switch ev.Type {
		case models.FeedEventImpression:
			row.Position = ev.Position
			if ev.VisibleMS > row.VisibleMS {
				row.VisibleMS = ev.VisibleMS
			}
		case models.FeedEventOpen:
			now := time.Now()
			row.OpenedAt = &now
		case models.FeedEventDwell:
			if ev.DwellMS > row.DwellMS {
				row.DwellMS = ev.DwellMS
			}
		}
	}

	return s.db.Transaction(func(tx *gorm.DB) error {
		for _, postID := range order {
			if err := s.upsertImpression(tx, merged[postID]); err != nil {
				return err
			}
		}
		return nil
	})
}

// upsertImpression 对唯一键做读改写合并：
//   - 已存在：opened_at 取更早非空值，dwell_ms / visible_ms 取最大；
//   - 不存在：直接插入。
func (s *FeedEventService) upsertImpression(tx *gorm.DB, incoming *models.FeedImpression) error {
	var existing models.FeedImpression
	err := tx.Where("user_id = ? AND post_id = ? AND feed_session_id = ? AND feed_kind = ?",
		incoming.UserID, incoming.PostID, incoming.FeedSessionID, incoming.FeedKind).
		First(&existing).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return tx.Clauses(clause.OnConflict{DoNothing: true}).Create(incoming).Error
	}
	if err != nil {
		return err
	}

	// 已存在：按幂等语义合并。
	existing.UpdatedAt = time.Now()
	if incoming.VisibleMS > existing.VisibleMS {
		existing.VisibleMS = incoming.VisibleMS
	}
	if incoming.DwellMS > existing.DwellMS {
		existing.DwellMS = incoming.DwellMS
	}
	if incoming.OpenedAt != nil {
		if existing.OpenedAt == nil || incoming.OpenedAt.Before(*existing.OpenedAt) {
			existing.OpenedAt = incoming.OpenedAt
		}
	}
	if incoming.Position != 0 {
		existing.Position = incoming.Position
	}
	if incoming.AlgorithmVersion != "" {
		existing.AlgorithmVersion = incoming.AlgorithmVersion
	}
	return tx.Save(&existing).Error
}

// CleanupExpired 删除 cutoff 之前更新过的曝光明细（FEED-2 TTL，默认 30 天）。
// 返回删除条数。聚合进 feed_daily_metrics 由 FEED-4 负责。
func (s *FeedEventService) CleanupExpired(ctx context.Context, cutoff time.Time) (int64, error) {
	res := s.db.WithContext(ctx).
		Where("updated_at < ?", cutoff).
		Delete(&models.FeedImpression{})
	return res.RowsAffected, res.Error
}
