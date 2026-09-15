package models

import "gorm.io/gorm"

// 申诉结案时对处理管理员的经验调整。
//
// 立即结案（handlers/appeal.go）与到期兜底结案（tasks/appeal_finalizer.go）必须
// 共用这里的实现：两个事务并发结案时各自只持有 appeals 行的锁、不锁 users 行，
// 任何"先读后写"都会丢掉一次调整（两个申诉同时成立时 10 应扣到 4，实际只扣到 7），
// 所以只能用数据库侧的原子表达式。
const (
	appealPassAdminExpPenalty  = 3 // 申诉成立：处理管理员扣减
	appealRejectAdminExpReward = 5 // 申诉被驳回：处理管理员奖励
)

// PenalizeAdminExpOnAppealPass 用原子表达式扣减管理员经验，扣到 0 为止。
func PenalizeAdminExpOnAppealPass(tx *gorm.DB, adminID uint) error {
	return tx.Model(&User{}).Where("id = ?", adminID).
		Update("admin_exp", gorm.Expr(
			"CASE WHEN admin_exp >= ? THEN admin_exp - ? ELSE 0 END",
			appealPassAdminExpPenalty, appealPassAdminExpPenalty,
		)).Error
}

// RewardAdminExpOnAppealReject 用原子表达式给处理管理员加经验。
func RewardAdminExpOnAppealReject(tx *gorm.DB, adminID uint) error {
	return tx.Model(&User{}).Where("id = ?", adminID).
		Update("admin_exp", gorm.Expr("admin_exp + ?", appealRejectAdminExpReward)).Error
}
