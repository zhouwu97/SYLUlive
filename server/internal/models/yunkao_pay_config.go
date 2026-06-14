package models

import "time"

// YunkaoPayConfig 融智云考助手 - 支付配置（全局单例，存储在 system_configs 表中）
// 使用 config_key 前缀 "yunkao_pay_" 区分

// 以下是存储键名常量
const (
	YunkaoPayGatewayType  = "yunkao_pay_gateway_type"  // "epay" or "vmq"
	YunkaoPayAppID        = "yunkao_pay_app_id"
	YunkaoPayAppSecret    = "yunkao_pay_app_secret"
	YunkaoPayApiURL       = "yunkao_pay_api_url"
	YunkaoPayVmqSecret    = "yunkao_pay_vmq_secret"
	YunkaoPayVmqApiURL    = "yunkao_pay_vmq_api_url"
	YunkaoPayEnabled      = "yunkao_pay_enabled"
	YunkaoPayMinAmount    = "yunkao_pay_min_amount"    // 最低充值金额，单位：分
	YunkaoPayNotifyBase   = "yunkao_pay_notify_base"   // 回调基地址
)

// YunkaoPayOrder 融智云考助手 - 在线支付订单
type YunkaoPayOrder struct {
	ID            uint       `gorm:"primaryKey" json:"id"`
	OrderNo       string     `gorm:"uniqueIndex;size:64;not null" json:"order_no"`
	UserID        uint       `gorm:"index;not null" json:"user_id"`
	AmountCents   int        `gorm:"not null" json:"amount_cents"`    // 订单金额，单位：分
	Gateway       string     `gorm:"size:20;default:'epay'" json:"gateway"` // epay / vmq
	PayType       string     `gorm:"size:10;default:'alipay'" json:"pay_type"` // alipay / wechat
	Status        string     `gorm:"size:20;default:'pending'" json:"status"`  // pending / completed / cancelled
	TradeNo       string     `gorm:"size:100" json:"trade_no"`       // 第三方交易号
	RealAmountCents int      `gorm:"default:0" json:"real_amount_cents"` // V免签实际收款金额
	PaidAt        *time.Time `json:"paid_at"`
	CreatedAt     time.Time  `gorm:"default:CURRENT_TIMESTAMP" json:"created_at"`
	UpdatedAt     time.Time  `json:"updated_at"`
}

func (YunkaoPayOrder) TableName() string {
	return "yunkao_pay_orders"
}
