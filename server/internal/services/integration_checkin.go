package services

import (
	"context"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
)

// CheckInForBinding 与撤权遵守相同的用户行→授权行锁顺序；复用 App 签到事务，
// 不接受外部账号、日期、补签或经验参数。旧只读授权不能由此取得写权限。
func (s *IntegrationAuthService) CheckInForBinding(ctx context.Context, expected models.IntegrationBinding, submit bool) (interface{}, error) {
	var result interface{}
	if expected.OwnerID == 0 {
		return nil, integrationError("authentication_required", 401)
	}
	release := AcquireContentWriteSerialLock(s.DB)
	defer release()
	err := s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var user models.User
		// App 签到会取得 UPDATE 锁；一开始用同一强度，避免持有授权锁后升级用户锁。
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, expected.OwnerID).Error; err != nil {
			return err
		}
		var current models.IntegrationBinding
		if err := tx.Clauses(clause.Locking{Strength: "NO KEY UPDATE"}).
			Where("id = ? AND owner_id = ?", expected.ID, user.ID).Take(&current).Error; err != nil {
			return integrationError("invalid_token", 401)
		}
		if current.Epoch != expected.Epoch {
			return integrationError("authorization_changed", 403)
		}
		if err := s.bindingValid(tx, current, user); err != nil {
			return err
		}
		if !IntegrationHasScope(current, IntegrationCheckInScope) {
			return integrationError("insufficient_scope", 403)
		}
		location, err := time.LoadLocation("Asia/Shanghai")
		if err != nil {
			return err
		}
		service := NewCheckInService(tx)
		now := s.Now().In(location)
		if !submit {
			status, err := service.Status(user.ID, now)
			result = map[string]interface{}{"checked_in": status.CheckedIn, "check_in_date": FormatCheckInDate(status.CheckInDate), "streak_days": status.StreakDays, "next_exp": status.NextExp}
			return err
		}
		signed, err := service.CheckIn(user.ID, now)
		if err != nil {
			return err
		}
		result = map[string]interface{}{"already": signed.Already, "check_in_date": FormatCheckInDate(signed.CheckInDate), "streak_days": signed.StreakDays, "exp_earned": signed.ExpEarned, "makeup_cards_awarded": signed.MakeupCardsAwarded}
		return tx.Create(&models.IntegrationAudit{OwnerID: user.ID, BindingID: current.ID, Event: "daily_checkin", CreatedAt: s.Now()}).Error
	})
	return result, err
}
