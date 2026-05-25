package models

import "time"

// CachedQuestion 题库缓存模型
type CachedQuestion struct {
	QuestionHash string    `gorm:"primaryKey;size:64" json:"question_hash"` // 题干+选项清洗后的 SHA256 值
	QuestionType string    `gorm:"size:20;not null" json:"question_type"`   // 单选/多选/填空等
	RawContent   string    `gorm:"type:json;not null" json:"raw_content"`   // 原始题目完整 JSON
	AiAnswer     string    `gorm:"type:text;not null" json:"ai_answer"`     // AI 计算出的最终答案
	CreatedAt    time.Time `gorm:"default:CURRENT_TIMESTAMP" json:"created_at"`
}
