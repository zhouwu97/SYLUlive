package models

import "time"

// CheckIn 是每天签到的不可变事实记录。签到日期使用 DATE，避免时区导致同一天重复。
type CheckIn struct {
	ID          uint      `gorm:"primaryKey" json:"id"`
	UserID      uint      `gorm:"not null;index" json:"user_id"`
	CheckInDate time.Time `gorm:"type:date;not null;index" json:"check_in_date"`
	StreakDays  int       `gorm:"not null;default:1" json:"streak_days"`
	ExpEarned   int       `gorm:"not null;default:1" json:"exp_earned"`
	IsMakeup    bool      `gorm:"not null;default:false;index" json:"is_makeup"`
	CreatedAt   time.Time `json:"created_at"`
}

// UserCheckInStat 保存签到事实的可重建汇总，绝不能作为签到是否成功的依据。
type UserCheckInStat struct {
	UserID             uint       `gorm:"primaryKey" json:"user_id"`
	LastCheckInDate    *time.Time `gorm:"type:date" json:"last_check_in_date,omitempty"`
	CurrentStreak      int        `gorm:"not null;default:0" json:"current_streak"`
	LongestStreak      int        `gorm:"not null;default:0" json:"longest_streak"`
	MakeupCardsEarned  int        `gorm:"not null;default:0" json:"makeup_cards_earned"`
	MakeupCardsGranted int        `gorm:"not null;default:0" json:"makeup_cards_granted"`
	MakeupCardsUsed    int        `gorm:"not null;default:0" json:"makeup_cards_used"`
	UpdatedAt          time.Time  `json:"updated_at"`
}

// CheckInRepairLog 记录人工补录、回算等修改签到事实或汇总的操作，便于审计和回滚追踪。
type CheckInRepairLog struct {
	ID             uint      `gorm:"primaryKey" json:"id"`
	UserID         uint      `gorm:"not null;index" json:"user_id"`
	OperatorID     uint      `gorm:"not null;index" json:"operator_id"`
	Action         string    `gorm:"size:50;not null;index" json:"action"`
	Reason         string    `gorm:"size:500;not null" json:"reason"`
	PreviousStreak int       `gorm:"not null;default:0" json:"previous_streak"`
	NewStreak      int       `gorm:"not null;default:0" json:"new_streak"`
	ExpDelta       int       `gorm:"not null;default:0" json:"exp_delta"`
	CreatedAt      time.Time `json:"created_at"`
}

const (
	CheckInCompensationCampaignPublished = "published"
	CheckInCompensationCampaignClosed    = "closed"
)

// CheckInCompensationCampaign 是一次补偿活动的定义；资格必须在发布时快照化。
type CheckInCompensationCampaign struct {
	ID             uint      `gorm:"primaryKey" json:"id"`
	Title          string    `gorm:"size:120;not null" json:"title"`
	Description    string    `gorm:"size:1000;not null;default:''" json:"description"`
	Status         string    `gorm:"size:20;not null;index" json:"status"`
	ClaimStartDate time.Time `gorm:"type:date;not null" json:"claim_start_date"`
	ClaimEndDate   time.Time `gorm:"type:date;not null" json:"claim_end_date"`
	PublishedAt    time.Time `json:"published_at"`
	CreatedBy      uint      `gorm:"not null;index" json:"created_by"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

// CheckInCompensationEligibility 是活动发布时写入的资格快照；一条对应一个补偿日期。
type CheckInCompensationEligibility struct {
	ID          uint      `gorm:"primaryKey" json:"id"`
	CampaignID  uint      `gorm:"not null;index" json:"campaign_id"`
	UserID      uint      `gorm:"not null;index" json:"user_id"`
	CheckInDate time.Time `gorm:"type:date;not null;index" json:"check_in_date"`
	ExpReward   int       `gorm:"not null" json:"exp_reward"`
	Reason      string    `gorm:"size:500;not null;default:''" json:"reason"`
	CreatedAt   time.Time `json:"created_at"`
}

// CheckInCompensationClaim 是用户实际领取的流水。一日一条，支持多日活动逐日领取。
type CheckInCompensationClaim struct {
	ID          uint      `gorm:"primaryKey" json:"id"`
	CampaignID  uint      `gorm:"not null;index" json:"campaign_id"`
	UserID      uint      `gorm:"not null;index" json:"user_id"`
	CheckInDate time.Time `gorm:"type:date;not null;index" json:"check_in_date"`
	ExpReward   int       `gorm:"not null" json:"exp_reward"`
	ClaimedAt   time.Time `json:"claimed_at"`
	CreatedAt   time.Time `json:"created_at"`
}

// UserExperienceLedger 记录签到域产生的经验变动，users.exp 仅作为总额缓存。
type UserExperienceLedger struct {
	ID         uint      `gorm:"primaryKey" json:"id"`
	UserID     uint      `gorm:"not null;index" json:"user_id"`
	SourceType string    `gorm:"size:50;not null;index" json:"source_type"`
	SourceID   uint      `gorm:"not null;index" json:"source_id"`
	Delta      int       `gorm:"not null" json:"delta"`
	Reason     string    `gorm:"size:500;not null;default:''" json:"reason"`
	CreatedAt  time.Time `json:"created_at"`
}
