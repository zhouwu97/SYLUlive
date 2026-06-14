package models

import "time"

// AiUsageLog 记录每次 AI / 缓存答题的计费与 token 使用情况
type AiUsageLog struct {
	ID                  uint      `gorm:"primaryKey" json:"id"`
	UserID              uint      `gorm:"index;not null" json:"user_id"`
	QuestionHash        string    `gorm:"size:64;index;not null" json:"question_hash"`
	QuestionType        string    `gorm:"size:20;not null" json:"question_type"`
	Source              string    `gorm:"size:20;not null" json:"source"`
	Provider            string    `gorm:"size:32" json:"provider"`
	ModelName           string    `gorm:"size:64" json:"model_name"`
	PromptTokens        int       `gorm:"default:0" json:"prompt_tokens"`
	CompletionTokens    int       `gorm:"default:0" json:"completion_tokens"`
	TotalTokens         int       `gorm:"default:0" json:"total_tokens"`
	BilledAmountCents   int       `gorm:"default:0" json:"billed_amount_cents"`
	ReservedAmountCents int       `gorm:"default:0" json:"reserved_amount_cents"`
	BalanceAfterCents   int       `gorm:"default:0" json:"balance_after_cents"`
	CacheHit            bool      `gorm:"index" json:"cache_hit"`
	CreatedAt           time.Time `gorm:"default:CURRENT_TIMESTAMP" json:"created_at"`
}
