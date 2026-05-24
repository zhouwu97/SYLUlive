package models

import (
	"time"
)

type LotteryEvent struct {
	ID          uint                 `gorm:"primarykey" json:"id"`
	CreatedAt   time.Time            `json:"created_at"`
	UpdatedAt   time.Time            `json:"updated_at"`
	Title       string               `gorm:"size:100;not null" json:"title"`
	Description string               `gorm:"type:text" json:"description"`
	PrizeName   string               `gorm:"size:100;not null" json:"prize_name"`
	DrawTime    time.Time            `json:"draw_time"`
	Status      int                  `gorm:"default:0" json:"status"` // 0: Upcoming/Ongoing, 1: Drawn
	WinnerID    *uint                `json:"winner_id"`
	Winner      *User                `gorm:"foreignKey:WinnerID" json:"winner,omitempty"`
	Participants []LotteryParticipant `gorm:"foreignKey:LotteryID" json:"participants,omitempty"`
}

type LotteryParticipant struct {
	ID        uint      `gorm:"primarykey" json:"id"`
	CreatedAt time.Time `json:"created_at"`
	LotteryID uint      `gorm:"uniqueIndex:idx_lottery_user;not null" json:"lottery_id"`
	UserID    uint      `gorm:"uniqueIndex:idx_lottery_user;not null" json:"user_id"`
	Weight    int       `gorm:"default:1;not null" json:"weight"`
	User      User      `gorm:"foreignKey:UserID" json:"user"`
}
