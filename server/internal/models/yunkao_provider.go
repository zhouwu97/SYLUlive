package models

import "time"

// YunkaoAiProvider 融智云考助手 - 官方 AI 提供商
type YunkaoAiProvider struct {
	ID          uint      `gorm:"primaryKey" json:"id"`
	ProviderKey string    `gorm:"uniqueIndex;size:32;not null" json:"provider_key"` // openai, deepseek, kimi, qwen, glm, mimo, custom
	Label       string    `gorm:"size:64;not null" json:"label"`                     // 展示名称
	BaseURL     string    `gorm:"size:256;not null" json:"base_url"`
	AuthHeader  string    `gorm:"size:64;default:'Authorization'" json:"auth_header"`
	AuthPrefix  string    `gorm:"size:32;default:'Bearer '" json:"auth_prefix"`
	APIKey      string    `gorm:"size:512" json:"api_key"` // 提供商默认 API Key
	Enabled     bool      `gorm:"default:true;index" json:"enabled"`
	Priority    int       `gorm:"default:0" json:"priority"`
	CreatedAt   time.Time `gorm:"default:CURRENT_TIMESTAMP" json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

func (YunkaoAiProvider) TableName() string {
	return "yunkao_ai_providers"
}
