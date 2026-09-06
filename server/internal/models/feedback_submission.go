package models

import "time"

// FeedbackSubmission 只保存反馈限流所需的不可逆摘要，不保存 IP 或反馈正文。
type FeedbackSubmission struct {
	ID          uint      `gorm:"primaryKey"`
	IPHash      string    `gorm:"size:64;not null;index:idx_feedback_submissions_ip_time"`
	ContentHash string    `gorm:"size:64;not null;index:idx_feedback_submissions_content_time"`
	UserID      *uint     `gorm:"index"`
	EmailSent   bool      `gorm:"not null;default:false;index"`
	CreatedAt   time.Time `gorm:"index"`
}
