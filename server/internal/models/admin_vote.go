package models

import "time"

// AdminVote 罢免管理员投票
type AdminVote struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	AdminID   uint      `gorm:"index;not null" json:"admin_id"`
	VoterID   uint      `gorm:"uniqueIndex:idx_voter_admin;not null" json:"voter_id"`
	CreatedAt time.Time `json:"created_at"`
}
