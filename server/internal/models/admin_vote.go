package models

import "time"

// AdminVote 罢免管理员投票
type AdminVote struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	AdminID   uint      `gorm:"index;not null" json:"admin_id"`
	VoterID   uint      `gorm:"uniqueIndex:idx_voter_admin;not null" json:"voter_id"`
	Reason    string    `gorm:"size:500" json:"reason"`
	CreatedAt time.Time `json:"created_at"`
}

// AdminRemovalVote 管理员罢免投票。保留 AdminVote 兼容旧数据，新流程使用本表。
type AdminRemovalVote struct {
	ID            uint      `gorm:"primaryKey" json:"id"`
	TargetAdminID uint      `gorm:"uniqueIndex:idx_removal_target_voter;not null" json:"target_admin_id"`
	VoterID       uint      `gorm:"uniqueIndex:idx_removal_target_voter;not null" json:"voter_id"`
	Reason        string    `gorm:"size:500;not null" json:"reason"`
	CreatedAt     time.Time `json:"created_at"`

	TargetAdmin User `gorm:"foreignKey:TargetAdminID" json:"target_admin,omitempty"`
	Voter       User `gorm:"foreignKey:VoterID" json:"voter,omitempty"`
}
