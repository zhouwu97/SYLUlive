package models

import "time"

// YunkaoAiModel 融智云考助手 - 模型配置（三段式百万 tokens 定价）
type YunkaoAiModel struct {
	ID                     uint      `gorm:"primaryKey" json:"id"`
	ProviderID             uint      `gorm:"index;not null" json:"provider_id"`
	ProviderKey            string    `gorm:"size:32;index;not null" json:"provider_key"` // 冗余字段，方便前端直接使用
	ModelName              string    `gorm:"size:128;not null" json:"model_name"`
	Label                  string    `gorm:"size:128" json:"label"`         // 展示标签
	SupportsVision         bool      `gorm:"default:false" json:"supports_vision"`
	CacheHitInputPrice1MCents  int   `gorm:"default:0" json:"cache_hit_input_price_1m_cents"`  // 百万 tokens 输入（缓存命中）价格，单位：分
	LiveInputPrice1MCents      int   `gorm:"default:0" json:"live_input_price_1m_cents"`       // 百万 tokens 输入（缓存未命中）价格，单位：分
	OutputPrice1MCents         int   `gorm:"default:0" json:"output_price_1m_cents"`           // 百万 tokens 输出价格，单位：分
	ImageSurchargeCents        int   `gorm:"default:0" json:"image_surcharge_cents"`           // 图片题附加价，单位：分/次
	IsDefault              bool      `gorm:"default:false" json:"is_default"`  // 是否默认推荐
	Enabled                bool      `gorm:"default:true;index" json:"enabled"`
	Priority               int       `gorm:"default:0" json:"priority"`
	CreatedAt              time.Time `gorm:"default:CURRENT_TIMESTAMP" json:"created_at"`
	UpdatedAt              time.Time `json:"updated_at"`
}

func (YunkaoAiModel) TableName() string {
	return "yunkao_ai_models"
}
