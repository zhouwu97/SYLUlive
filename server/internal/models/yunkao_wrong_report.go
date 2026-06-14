package models

import "time"

// YunkaoWrongReport 融智云考助手 - 错题报告
type YunkaoWrongReport struct {
	ID               uint       `gorm:"primaryKey" json:"id"`
	UserID           uint       `gorm:"index;not null" json:"user_id"`
	QuestionHash     string     `gorm:"size:64;index;not null" json:"question_hash"`
	UsageLogID       uint       `gorm:"default:0" json:"usage_log_id"`     // 关联 yunkao_usage_logs.id
	ExportJobID      string     `gorm:"size:64;index" json:"export_job_id"`
	QuestionSnapshot string     `gorm:"type:json" json:"question_snapshot"` // 题目快照
	CurrentAnswer    string     `gorm:"type:text" json:"current_answer"`    // 当前缓存答案
	ReportReason     string     `gorm:"size:256" json:"report_reason"`      // 用户标错原因
	Status           string     `gorm:"size:20;default:'pending';index" json:"status"` // pending / reviewing / approved / rejected
	RewriteAnswer    string     `gorm:"type:text" json:"rewrite_answer"`    // 重答后的答案
	FinalAnswer      string     `gorm:"type:text" json:"final_answer"`      // 人工修正后的最终答案
	ReviewedBy       uint       `gorm:"default:0" json:"reviewed_by"`
	ReviewedAt       *time.Time `json:"reviewed_at"`
	CreatedAt        time.Time  `gorm:"default:CURRENT_TIMESTAMP" json:"created_at"`
	UpdatedAt        time.Time  `json:"updated_at"`
}

func (YunkaoWrongReport) TableName() string {
	return "yunkao_wrong_reports"
}
