package models

import "time"

const (
	OneClassTierOneTime         = "one_time"
	OneClassTierLifetimeUpdates = "lifetime_updates"
	OneClassTierUpgradeUpdates  = "upgrade_updates"
)

// OneClassPayOrder 记录 oneclass 的公开购买订单。
type OneClassPayOrder struct {
	ID              uint       `gorm:"primaryKey" json:"id"`
	OrderNo         string     `gorm:"uniqueIndex;size:64;not null" json:"order_no"`
	Tier            string     `gorm:"size:32;not null;index" json:"tier"`
	Title           string     `gorm:"size:64;not null" json:"title"`
	MachineID       string     `gorm:"size:128;index" json:"machine_id"`
	Contact         string     `gorm:"size:128" json:"contact"`
	AmountCents     int        `gorm:"not null" json:"amount_cents"`
	PayType         string     `gorm:"size:10;default:'alipay'" json:"pay_type"`
	Status          string     `gorm:"size:20;default:'pending';index" json:"status"`
	TradeNo         string     `gorm:"size:100" json:"trade_no"`
	GatewayPayURL   string     `gorm:"type:text" json:"-"`
	GatewayQRCode   string     `gorm:"type:text" json:"-"`
	GatewayScheme   string     `gorm:"type:text" json:"-"`
	PaidAt          *time.Time `json:"paid_at"`
	CreatedAt       time.Time  `gorm:"default:CURRENT_TIMESTAMP" json:"created_at"`
	UpdatedAt       time.Time  `json:"updated_at"`
}

func (OneClassPayOrder) TableName() string {
	return "oneclass_pay_orders"
}
