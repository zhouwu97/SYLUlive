package models

import (
	"time"
)

// ReportStatus 举报状态
type ReportStatus string

const (
	ReportStatusPending  ReportStatus = "pending"  // 待处理
	ReportStatusHandled  ReportStatus = "handled" // 已处理
	ReportStatusIgnored  ReportStatus = "ignored" // 已忽略
)

// Report 举报
type Report struct {
	ID           uint         `gorm:"primaryKey" json:"id"`
	ReporterID   uint         `gorm:"not null;index" json:"reporter_id"`
	TargetType   string       `gorm:"size:20;not null;index" json:"target_type"` // post/reply
	TargetID     uint         `gorm:"not null;index" json:"target_id"`
	Reason       string       `gorm:"type:text;not null" json:"reason"`
	Status       ReportStatus `gorm:"default:pending;index" json:"status"`
	HandlerID    *uint        `json:"handler_id"`
	Result       string       `gorm:"size:500" json:"result"`       // 处理结果说明
	DeleteReason string       `gorm:"size:500" json:"delete_reason"` // 删除理由
	CreatedAt    time.Time    `json:"created_at"`
	HandledAt    *time.Time   `json:"handled_at"`
	Reporter     User         `gorm:"foreignKey:ReporterID" json:"reporter"`
	Handler      *User        `gorm:"foreignKey:HandlerID" json:"handler"`
}

// AppealStatus 申诉状态
type AppealStatus string

const (
	AppealStatusPending AppealStatus = "pending" // 待投票
	AppealStatusPass    AppealStatus = "pass"    // 申诉成功
	AppealStatusReject  AppealStatus = "reject"   // 申诉失败
)

// Appeal 申诉
type Appeal struct {
	ID           uint         `gorm:"primaryKey" json:"id"`
	PostID       uint         `gorm:"not null" json:"post_id"`
	AppellantID  uint         `gorm:"not null" json:"appellant_id"`
	AdminID      uint         `gorm:"not null" json:"admin_id"`      // 处理此举报的管理员
	AdminReason  string       `gorm:"size:500" json:"admin_reason"` // 管理员删除理由
	Status       AppealStatus `gorm:"default:pending" json:"status"`
	Result       string       `gorm:"size:500" json:"result"`      // 最终结果
	CreatedAt    time.Time    `json:"created_at"`
	ClosedAt     *time.Time   `json:"closed_at"`
	Appellant     User        `gorm:"foreignKey:AppellantID" json:"appellant"`
	Admin         User        `gorm:"foreignKey:AdminID" json:"admin"`
	Post          Post        `gorm:"foreignKey:PostID" json:"post"`
}

// AppealVote 申诉投票
type AppealVote struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	AppealID  uint      `gorm:"not null;index" json:"appeal_id"`
	VoterID   uint      `gorm:"not null" json:"voter_id"`
	Vote      string    `gorm:"size:10;not null" json:"vote"` // support/oppose
	Comment   string    `gorm:"size:500" json:"comment"`
	CreatedAt time.Time `json:"created_at"`
	Voter     User      `gorm:"foreignKey:VoterID" json:"voter"`
}