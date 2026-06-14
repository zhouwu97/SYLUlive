package models

import "time"

// YunkaoRechargeOrder 融智云考助手 - 充值订单
type YunkaoRechargeOrder struct {
	ID            uint      `gorm:"primaryKey" json:"id"`
	UserID        uint      `gorm:"index;not null" json:"user_id"`
	AmountCents   int       `gorm:"not null" json:"amount_cents"`    // 充值金额，单位：分
	Type          string    `gorm:"size:20;not null" json:"type"`    // "manual" 管理员手工 / "online" 在线支付
	Status        string    `gorm:"size:20;default:'completed'" json:"status"` // pending / completed / cancelled
	OperatorID    uint      `gorm:"default:0" json:"operator_id"`   // 操作人（管理员 ID，手工充值时记录）
	Remark        string    `gorm:"size:256" json:"remark"`
	CreatedAt     time.Time `gorm:"default:CURRENT_TIMESTAMP" json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

func (YunkaoRechargeOrder) TableName() string {
	return "yunkao_recharge_orders"
}
