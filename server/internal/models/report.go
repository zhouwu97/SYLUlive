package models

import (
	"time"
)

// ReportStatus 举报状态
type ReportStatus string

const (
	ReportStatusPending ReportStatus = "pending" // 待处理
	ReportStatusHandled ReportStatus = "handled" // 已处理
	ReportStatusIgnored ReportStatus = "ignored" // 已忽略
)

// Report 举报
type Report struct {
	ID             uint         `gorm:"primaryKey" json:"id"`
	ReporterID     uint         `gorm:"not null;index" json:"reporter_id"`
	TargetType     string       `gorm:"size:20;not null;index" json:"target_type"` // post/reply/teacher_rating/major_rating
	TargetID       uint         `gorm:"not null;index" json:"target_id"`
	ReasonCode     string       `gorm:"size:50;index" json:"reason_code"`
	Reason         string       `gorm:"type:text;not null" json:"reason"`
	TargetAuthorID *uint        `gorm:"index" json:"target_author_id"`
	TargetSnapshot string       `gorm:"type:text" json:"target_snapshot"`
	Action         string       `gorm:"size:50" json:"action"`
	Status         ReportStatus `gorm:"default:pending;index" json:"status"`
	HandlerID      *uint        `json:"handler_id"`
	Result         string       `gorm:"size:500" json:"result"`        // 处理结果说明
	DeleteReason   string       `gorm:"size:500" json:"delete_reason"` // 删除理由
	CreatedAt      time.Time    `json:"created_at"`
	HandledAt      *time.Time   `json:"handled_at"`
	Reporter       User         `gorm:"foreignKey:ReporterID" json:"reporter"`
	Handler        *User        `gorm:"foreignKey:HandlerID" json:"handler"`
}

// AppealStatus 申诉状态
type AppealStatus string

const (
	AppealStatusPending AppealStatus = "pending" // 待投票
	AppealStatusPass    AppealStatus = "pass"    // 申诉成功
	AppealStatusReject  AppealStatus = "reject"  // 申诉失败
)

// Appeal 申诉
type Appeal struct {
	ID             uint         `gorm:"primaryKey" json:"id"`
	PostID         uint         `gorm:"not null" json:"post_id"`
	AppellantID    uint         `gorm:"not null" json:"appellant_id"`
	AdminID        uint         `gorm:"not null" json:"admin_id"`     // 处理此举报的管理员
	AdminReason    string       `gorm:"size:500" json:"admin_reason"` // 管理员删除理由
	Status         AppealStatus `gorm:"default:pending" json:"status"`
	Result         string       `gorm:"size:500" json:"result"` // 最终结果
	VotingDeadline *time.Time   `gorm:"index" json:"voting_deadline"`
	RequiredVotes  int          `gorm:"not null;default:1" json:"required_votes"`
	ClosedReason   string       `gorm:"size:100" json:"closed_reason"`
	CreatedAt      time.Time    `json:"created_at"`
	ClosedAt       *time.Time   `json:"closed_at"`
	Appellant      User         `gorm:"foreignKey:AppellantID" json:"appellant"`
	Admin          User         `gorm:"foreignKey:AdminID" json:"admin"`
	Post           Post         `gorm:"foreignKey:PostID" json:"post"`
}

// AppealVote 申诉投票
type AppealVote struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	AppealID  uint      `gorm:"not null;uniqueIndex:idx_appeal_voter" json:"appeal_id"`
	VoterID   uint      `gorm:"not null;uniqueIndex:idx_appeal_voter" json:"voter_id"`
	Vote      string    `gorm:"size:10;not null" json:"vote"` // support/oppose
	Comment   string    `gorm:"size:500" json:"comment"`
	CreatedAt time.Time `json:"created_at"`
	Voter     User      `gorm:"foreignKey:VoterID" json:"voter"`
}

// PublicAppealUserResponse 是申诉接口允许展示的最小用户资料。
type PublicAppealUserResponse struct {
	ID       uint   `json:"id"`
	Nickname string `json:"nickname"`
	Avatar   string `json:"avatar"`
}

type AppealPostResponse struct {
	ID      uint       `json:"id"`
	Title   string     `json:"title"`
	Content string     `json:"content"`
	Status  PostStatus `json:"status"`
}

type AppealResponse struct {
	ID             uint                     `json:"id"`
	PostID         uint                     `json:"post_id"`
	AdminReason    string                   `json:"admin_reason"`
	Status         AppealStatus             `json:"status"`
	Result         string                   `json:"result"`
	VotingDeadline *time.Time               `json:"voting_deadline"`
	RequiredVotes  int                      `json:"required_votes"`
	ClosedReason   string                   `json:"closed_reason"`
	CreatedAt      time.Time                `json:"created_at"`
	ClosedAt       *time.Time               `json:"closed_at"`
	Appellant      PublicAppealUserResponse `json:"appellant"`
	Admin          PublicAppealUserResponse `json:"admin"`
	Post           AppealPostResponse       `json:"post"`
}

type AppealVoteResponse struct {
	ID        uint                     `json:"id"`
	AppealID  uint                     `json:"appeal_id"`
	Vote      string                   `json:"vote"`
	Comment   string                   `json:"comment"`
	CreatedAt time.Time                `json:"created_at"`
	Voter     PublicAppealUserResponse `json:"voter"`
}
