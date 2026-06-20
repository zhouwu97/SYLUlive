package models

import "time"

// YunkaoWallet 融智云考助手 - 独立钱包
type YunkaoWallet struct {
	ID                 uint      `gorm:"primaryKey" json:"id"`
	UserID             uint      `gorm:"uniqueIndex;not null" json:"user_id"`
	BalanceCents       int       `gorm:"default:0" json:"balance_cents"`        // 当前余额，单位：分
	TotalRechargedCents int      `gorm:"default:0" json:"total_recharged_cents"` // 累计充值，单位：分
	TotalSpentCents    int       `gorm:"default:0" json:"total_spent_cents"`     // 累计消费，单位：分
	CreatedAt          time.Time `gorm:"default:CURRENT_TIMESTAMP" json:"created_at"`
	UpdatedAt          time.Time `json:"updated_at"`
}

func (YunkaoWallet) TableName() string {
	return "yunkao_wallets"
}
