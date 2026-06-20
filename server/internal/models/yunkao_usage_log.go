package models

import "time"

// YunkaoUsageLog 融智云考助手 - AI 调用使用日志
type YunkaoUsageLog struct {
	ID               uint      `gorm:"primaryKey" json:"id"`
	UserID           uint      `gorm:"index;not null" json:"user_id"`
	QuestionHash     string    `gorm:"size:64;index;not null" json:"question_hash"`
	ExportJobID      string    `gorm:"size:64;index" json:"export_job_id"`   // 关联的导出批次
	ProviderKey      string    `gorm:"size:32;not null" json:"provider_key"`
	ModelName        string    `gorm:"size:128;not null" json:"model_name"`
	ModelID          uint      `gorm:"default:0" json:"model_id"`            // 关联 yunkao_ai_models.id
	PromptTokens     int       `gorm:"default:0" json:"prompt_tokens"`
	CompletionTokens int       `gorm:"default:0" json:"completion_tokens"`
	TotalTokens      int       `gorm:"default:0" json:"total_tokens"`
	BilledAmountCents int      `gorm:"default:0" json:"billed_amount_cents"` // 实扣金额，单位：分
	CacheHit         bool      `gorm:"index" json:"cache_hit"`
	HasImage         bool      `gorm:"default:false" json:"has_image"`       // 是否图片题
	SourceType       string    `gorm:"size:20;default:'official'" json:"source_type"` // official / cache
	CreatedAt        time.Time `gorm:"default:CURRENT_TIMESTAMP" json:"created_at"`
}

func (YunkaoUsageLog) TableName() string {
	return "yunkao_usage_logs"
}
