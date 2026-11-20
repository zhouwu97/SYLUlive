package services

import (
	"context"
	"strings"
	"time"

	"shenliyuan/internal/models"
)

const (
	LoginPatternWindow      = 10 * time.Minute
	LoginPatternMinTargets  = 20
	LoginPatternMinFailures = 100
)

type LoginFailurePattern struct {
	DistinctTargets int64
	FailedAttempts  int64
}

func (p LoginFailurePattern) NeedsReview() bool {
	return p.DistinctTargets >= LoginPatternMinTargets && p.FailedAttempts >= LoginPatternMinFailures
}

// LoginFailurePatternContext 只统计实际未通过验证的登录；冷却期间未验密的重复请求不作为喷洒证据。
func (s *SecurityEventService) LoginFailurePatternContext(ctx context.Context, clientIP string, since time.Time) (LoginFailurePattern, error) {
	var pattern LoginFailurePattern
	if s == nil || s.db == nil || strings.TrimSpace(clientIP) == "" {
		return pattern, nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, securityAuditTimeout)
	defer cancel()
	// 不包含跨过区间起点的旧聚合桶，避免把区间外的失败带进来误报。
	err := s.db.WithContext(ctx).Model(&models.SecurityEvent{}).
		Select("COUNT(DISTINCT target_hash) AS distinct_targets, COALESCE(SUM(attempt_count), 0) AS failed_attempts").
		Where("event_type = ? AND first_seen_at >= ? AND target_hash <> '' AND source_ip_hash = ? AND source_attribution_valid = ?", "login_failed", since.UTC(), s.Hash(clientIP), true).
		Scan(&pattern).Error
	return pattern, err
}
