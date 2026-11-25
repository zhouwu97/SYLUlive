package models

import (
	"time"
)

const (
	LotteryStatusOngoing   = 0 // 进行中
	LotteryStatusDrawn     = 1 // 已开奖（产生中奖者）
	LotteryStatusNoWinner  = 2 // 已流拍（无有效参与者）
	LotteryStatusCancelled = 3 // 已取消（被新活动替代或提前关闭）

	LotteryDrawModeAuto   = "auto"
	LotteryDrawModeManual = "manual"
)

type LotteryEvent struct {
	ID           uint                 `gorm:"primarykey" json:"id"`
	CreatedAt    time.Time            `json:"created_at"`
	UpdatedAt    time.Time            `json:"updated_at"`
	Title        string               `gorm:"size:100;not null" json:"title"`
	Description  string               `gorm:"type:text" json:"description"`
	PrizeName    string               `gorm:"size:100;not null" json:"prize_name"`
	DrawTime     time.Time            `json:"draw_time"`
	Status       int                  `gorm:"default:0;index" json:"status"`
	WinnerID     *uint                `json:"winner_id"`
	DrawnAt      *time.Time           `json:"drawn_at,omitempty"`
	DrawMode     string               `gorm:"size:20;default:''" json:"draw_mode,omitempty"`
	CreatedBy    *uint                `json:"created_by,omitempty"`
	Winner       *User                `gorm:"foreignKey:WinnerID" json:"-"`
	Participants []LotteryParticipant `gorm:"foreignKey:LotteryID" json:"-"`
}

type LotteryParticipant struct {
	ID        uint      `gorm:"primarykey" json:"id"`
	CreatedAt time.Time `json:"created_at"`
	LotteryID uint      `gorm:"uniqueIndex:idx_lottery_user;not null" json:"lottery_id"`
	UserID    uint      `gorm:"uniqueIndex:idx_lottery_user;not null" json:"user_id"`
	Weight    int       `gorm:"default:1;not null" json:"weight"`
	User      User      `gorm:"foreignKey:UserID" json:"-"`
}
