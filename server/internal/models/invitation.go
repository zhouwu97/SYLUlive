package models

import (
	"time"
)

// InvitationStatus 邀请状态
type InvitationStatus string

const (
	InvitationStatusPending  InvitationStatus = "pending"  // 待接受
	InvitationStatusAccepted InvitationStatus = "accepted" // 已接受，待超管批准
	InvitationStatusApproved InvitationStatus = "approved" // 超管已批准
	InvitationStatusRejected InvitationStatus = "rejected" // 已拒绝
)

// Invitation 管理员邀请
type Invitation struct {
	ID         uint             `gorm:"primaryKey" json:"id"`
	UserID     uint             `gorm:"not null" json:"user_id"`    // 被邀请的用户
	InviterID  uint             `gorm:"not null" json:"inviter_id"` // 邀请人
	Reason     string           `gorm:"size:500" json:"reason"`     // 邀请理由
	Status     InvitationStatus `gorm:"default:pending" json:"status"`
	CreatedAt  time.Time        `json:"created_at"`
	AcceptedAt *time.Time       `json:"accepted_at"`
	User       User             `gorm:"foreignKey:UserID" json:"user"`
	Inviter    User             `gorm:"foreignKey:InviterID" json:"inviter"`
}

// InvitationVote 管理员邀请审批投票
type InvitationVote struct {
	ID           uint      `gorm:"primaryKey" json:"id"`
	InvitationID uint      `gorm:"uniqueIndex:idx_invitation_voter;not null" json:"invitation_id"`
	VoterID      uint      `gorm:"uniqueIndex:idx_invitation_voter;not null" json:"voter_id"`
	Reason       string    `gorm:"size:500" json:"reason"`
	CreatedAt    time.Time `json:"created_at"`

	Voter User `gorm:"foreignKey:VoterID" json:"voter,omitempty"`
}

// AdminActionLog 管理员操作日志
type AdminActionLog struct {
	ID         uint      `gorm:"primaryKey" json:"id"`
	AdminID    uint      `gorm:"not null" json:"admin_id"`
	Action     string    `gorm:"size:100;not null" json:"action"` // delete_post, handle_report, etc.
	TargetType string    `gorm:"size:50" json:"target_type"`
	TargetID   uint      `json:"target_id"`
	Detail     string    `gorm:"type:text" json:"detail"`
	CreatedAt  time.Time `json:"created_at"`
}
