package main

import (
	"context"
	"fmt"

	"gorm.io/gorm"

	"shenliyuan/internal/config"
	"shenliyuan/internal/services"
)

// validateAccountIdentityReadiness 在 S4 装配前执行脱敏对账；legacy 模式不阻塞 S1-S3 部署。
func validateAccountIdentityReadiness(ctx context.Context, db *gorm.DB, mode string) error {
	switch mode {
	case config.AccountIdentityReadModeLegacy:
		return nil
	case config.AccountIdentityReadModeIdentity:
		report, err := services.ReconcileEmailIdentityMirror(ctx, db)
		if err != nil {
			return fmt.Errorf("账号 Identity 启动对账失败: %w", err)
		}
		if report.MissingIdentity != 0 || report.MirrorMismatch != 0 || report.IdentityUserMismatch != 0 {
			return fmt.Errorf(
				"账号 Identity 读切换被拒绝: missing_identity=%d mirror_mismatch=%d identity_user_mismatch=%d",
				report.MissingIdentity, report.MirrorMismatch, report.IdentityUserMismatch,
			)
		}
		return nil
	default:
		return fmt.Errorf("未知账号 Identity 读模式 %q", mode)
	}
}
