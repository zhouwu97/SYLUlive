package models

import "time"

// YunkaoQuestionCache 融智云考助手 - 题库缓存（带状态机）
type YunkaoQuestionCache struct {
	QuestionHash     string    `gorm:"primaryKey;size:64" json:"question_hash"`
	QuestionType     string    `gorm:"size:20;not null" json:"question_type"`
	RawContent       string    `gorm:"type:json;not null" json:"raw_content"`
	AiAnswer         string    `gorm:"type:text;not null" json:"ai_answer"`
	ModelID          uint      `gorm:"default:0" json:"model_id"`
	ModelName        string    `gorm:"size:128" json:"model_name"`
	ProviderKey      string    `gorm:"size:32" json:"provider_key"`
	PromptTokens     int       `gorm:"default:0" json:"prompt_tokens"`
	CompletionTokens int       `gorm:"default:0" json:"completion_tokens"`
	TotalTokens      int       `gorm:"default:0" json:"total_tokens"`
	Status           string    `gorm:"size:20;default:'draft';index" json:"status"` // draft / verified / flagged / disabled
	ReportCount      int       `gorm:"default:0" json:"report_count"`
	RewriteCount     int       `gorm:"default:0" json:"rewrite_count"`
	VerifiedBy       uint      `gorm:"default:0" json:"verified_by"`
	VerifiedAt       *time.Time `json:"verified_at"`
	CreatedAt        time.Time `gorm:"default:CURRENT_TIMESTAMP" json:"created_at"`
	UpdatedAt        time.Time `json:"updated_at"`
}

func (YunkaoQuestionCache) TableName() string {
	return "yunkao_question_cache"
}
