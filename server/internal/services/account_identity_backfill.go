package services

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

// IdentityBackfillOptions 控制已验证邮箱的幂等回填。DryRun 不写任何数据。
type IdentityBackfillOptions struct {
	BatchSize int
	DryRun    bool
	Now       time.Time
	OnBatch   func(IdentityBackfillBatchReport) error
}

// IdentityBackfillReport 只含聚合计数，不返回邮箱、学号或冲突明细。
type IdentityBackfillReport struct {
	Scanned   int64
	Written   int64
	Skipped   int64
	Conflicts int64
	Invalid   int64
}

// IdentityBackfillBatchReport 只暴露单批聚合结果，供部署入口生成脱敏审计记录。
type IdentityBackfillBatchReport struct {
	Batch     int
	Scanned   int64
	Written   int64
	Skipped   int64
	Conflicts int64
	Invalid   int64
}

// BackfillVerifiedEmailIdentities 将 users 中已验证且无冲突的邮箱按 user.id 回填到
// user_login_identities。游标按主键递增，重复执行结果稳定且不会覆盖已有 Identity。
func BackfillVerifiedEmailIdentities(ctx context.Context, db *gorm.DB, options IdentityBackfillOptions) (IdentityBackfillReport, error) {
	var report IdentityBackfillReport
	if db == nil {
		return report, errors.New("identity backfill requires database")
	}
	if options.BatchSize <= 0 {
		options.BatchSize = 500
	}
	if options.Now.IsZero() {
		options.Now = time.Now().UTC()
	}
	options.Now = options.Now.UTC()
	var afterID uint
	batchNumber := 0
	for {
		var users []models.User
		query := db.WithContext(ctx).Where("id > ? AND email <> '' AND email_verified_at IS NOT NULL", afterID).
			Order("id ASC").Limit(options.BatchSize)
		if err := query.Find(&users).Error; err != nil {
			return report, err
		}
		if len(users) == 0 {
			return report, nil
		}
		batchNumber++
		beforeBatch := report
		for _, user := range users {
			afterID = user.ID
			report.Scanned++
			normalized, err := NormalizeEmail(user.Email)
			if err != nil {
				report.Invalid++
				continue
			}
			if options.DryRun {
				var existing models.UserLoginIdentity
				err := db.WithContext(ctx).
					Where("type = ? AND identifier_normalized = ?", models.LoginIdentityTypeEmail, normalized).
					Order("CASE WHEN disabled_at IS NULL THEN 0 ELSE 1 END").Order("id ASC").
					First(&existing).Error
				if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
					return report, err
				}
				switch {
				case errors.Is(err, gorm.ErrRecordNotFound):
					report.Written++
				case existing.UserID == user.ID:
					report.Skipped++
				default:
					report.Conflicts++
				}
				continue
			}
			skipped := false
			err = db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
				var existing models.UserLoginIdentity
				err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
					Where("type = ? AND identifier_normalized = ?", models.LoginIdentityTypeEmail, normalized).
					Order("CASE WHEN disabled_at IS NULL THEN 0 ELSE 1 END").Order("id ASC").
					First(&existing).Error
				if err == nil {
					if existing.UserID != user.ID {
						return ErrIdentityConflict
					}
					skipped = true
					return nil
				}
				if !errors.Is(err, gorm.ErrRecordNotFound) {
					return err
				}
				verifiedAt := user.EmailVerifiedAt
				if verifiedAt == nil {
					skipped = true
					return nil
				}
				identity := models.UserLoginIdentity{
					UserID: user.ID, Type: models.LoginIdentityTypeEmail,
					IdentifierNormalized: normalized, VerifiedAt: verifiedAt,
					CreatedAt: *verifiedAt, UpdatedAt: options.Now,
				}
				if err := tx.Create(&identity).Error; err != nil {
					return err
				}
				return nil
			})
			if err != nil {
				if errors.Is(err, ErrIdentityConflict) || isUniqueConstraintError(err) {
					report.Conflicts++
					continue
				}
				return report, err
			}
			if skipped {
				report.Skipped++
			} else {
				report.Written++
			}
		}
		if options.OnBatch != nil {
			batchReport := IdentityBackfillBatchReport{
				Batch:     batchNumber,
				Scanned:   report.Scanned - beforeBatch.Scanned,
				Written:   report.Written - beforeBatch.Written,
				Skipped:   report.Skipped - beforeBatch.Skipped,
				Conflicts: report.Conflicts - beforeBatch.Conflicts,
				Invalid:   report.Invalid - beforeBatch.Invalid,
			}
			if err := options.OnBatch(batchReport); err != nil {
				return report, fmt.Errorf("记录第 %d 批回填摘要失败: %w", batchNumber, err)
			}
		}
	}
}

// EmailIdentityReconcileReport 对账只返回差异计数。
type EmailIdentityReconcileReport struct {
	VerifiedEmailUsers    int64
	ActiveEmailIdentities int64
	MissingIdentity       int64
	MirrorMismatch        int64
	IdentityUserMismatch  int64
}

// ReconcileEmailIdentityMirror 比较有效 Identity、users.email 镜像和 user.id 映射。
func ReconcileEmailIdentityMirror(ctx context.Context, db *gorm.DB) (EmailIdentityReconcileReport, error) {
	var report EmailIdentityReconcileReport
	if db == nil {
		return report, errors.New("identity reconcile requires database")
	}
	base := db.WithContext(ctx)
	if err := base.Model(&models.User{}).Where("email <> '' AND email_verified_at IS NOT NULL").Count(&report.VerifiedEmailUsers).Error; err != nil {
		return report, err
	}
	if err := base.Model(&models.UserLoginIdentity{}).Where("type = ? AND disabled_at IS NULL AND verified_at IS NOT NULL", models.LoginIdentityTypeEmail).Count(&report.ActiveEmailIdentities).Error; err != nil {
		return report, err
	}
	// 使用规范化 SQL 聚合，不把任何冲突值装入内存或日志。
	if err := base.Table("users AS u").Joins("LEFT JOIN user_login_identities AS i ON i.user_id = u.id AND i.type = ? AND i.disabled_at IS NULL AND i.verified_at IS NOT NULL", models.LoginIdentityTypeEmail).
		Where("u.email <> '' AND u.email_verified_at IS NOT NULL AND (i.id IS NULL OR i.identifier_normalized <> u.email)").Count(&report.MirrorMismatch).Error; err != nil {
		return report, err
	}
	if err := base.Table("users AS u").Joins("LEFT JOIN user_login_identities AS i ON i.user_id = u.id AND i.type = ? AND i.disabled_at IS NULL AND i.verified_at IS NOT NULL", models.LoginIdentityTypeEmail).
		Where("u.email <> '' AND u.email_verified_at IS NOT NULL AND i.id IS NULL").Count(&report.MissingIdentity).Error; err != nil {
		return report, err
	}
	// 一个用户拥有多个有效邮箱 Identity 也属于对账差异。
	var duplicateRows int64
	if err := base.Model(&models.UserLoginIdentity{}).Where("type = ? AND disabled_at IS NULL AND verified_at IS NOT NULL", models.LoginIdentityTypeEmail).
		Select("user_id").Group("user_id").Having("COUNT(*) > 1").Count(&duplicateRows).Error; err != nil {
		return report, err
	}
	report.IdentityUserMismatch = duplicateRows
	return report, nil
}

func isUniqueConstraintError(err error) bool {
	if err == nil {
		return false
	}
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "unique") || strings.Contains(message, "duplicate") || strings.Contains(message, "constraint")
}
