package models

import (
	"time"

	"gorm.io/gorm"
)

const (
	UserCalendarSourceManual      = "manual"
	UserCalendarSourceCompetition = "competition"
	UserCalendarSourceAgentAction = "agent_action"
	UserCalendarCreatedByUser     = "user"
	UserCalendarCreatedByAgent    = "agent"

	UserCalendarActionCreate         = "calendar_event_create"
	UserCalendarActionUpdate         = "calendar_event_update"
	UserCalendarActionDelete         = "calendar_event_delete"
	UserCalendarActionReminderCreate = "calendar_reminder_create"
)

// UserCalendar 是通用个人日历容器。竞赛日历继续使用既有模型，统一视图在查询层合并。
type UserCalendar struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	UserID    uint      `gorm:"not null;uniqueIndex:idx_user_calendars_user_name,priority:1;index" json:"user_id"`
	Name      string    `gorm:"size:100;not null;uniqueIndex:idx_user_calendars_user_name,priority:2" json:"name"`
	Timezone  string    `gorm:"size:64;not null;default:'Asia/Shanghai'" json:"timezone"`
	IsDefault bool      `gorm:"not null;default:false;index" json:"is_default"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

func (UserCalendar) TableName() string { return "user_calendars" }

// UserCalendarEvent 保存用户明确创建或确认后的低风险日历事件。
// SourceID 使用字符串以兼容竞赛、通知和未来外部来源的不同 ID 形态。
type UserCalendarEvent struct {
	ID            uint           `gorm:"primaryKey" json:"id"`
	UserID        uint           `gorm:"not null;index:idx_user_calendar_events_user_time,priority:1" json:"user_id"`
	CalendarID    uint           `gorm:"not null;index" json:"calendar_id"`
	Title         string         `gorm:"size:160;not null" json:"title"`
	Description   string         `gorm:"type:text" json:"description"`
	StartAt       time.Time      `gorm:"not null;index:idx_user_calendar_events_user_time,priority:2" json:"start_at"`
	EndAt         time.Time      `gorm:"not null" json:"end_at"`
	AllDay        bool           `gorm:"not null;default:false" json:"all_day"`
	Location      string         `gorm:"size:200" json:"location"`
	Timezone      string         `gorm:"size:64;not null;default:'Asia/Shanghai'" json:"timezone"`
	SourceType    string         `gorm:"size:32;not null;default:'manual';index" json:"source_type"`
	SourceID      string         `gorm:"size:128;index" json:"source_id,omitempty"`
	SourceVersion int64          `gorm:"not null;default:1" json:"source_version"`
	SyncMode      string         `gorm:"size:24;not null;default:'snapshot'" json:"sync_mode"`
	Version       int64          `gorm:"not null;default:1" json:"version"`
	CreatedBy     string         `gorm:"size:24;not null;default:'user'" json:"created_by"`
	CreatedAt     time.Time      `json:"created_at"`
	UpdatedAt     time.Time      `json:"updated_at"`
	DeletedAt     gorm.DeletedAt `gorm:"index" json:"-"`
}

func (UserCalendarEvent) TableName() string { return "user_calendar_events" }

type UserCalendarReminder struct {
	ID            uint           `gorm:"primaryKey" json:"id"`
	UserID        uint           `gorm:"not null;index" json:"user_id"`
	EventID       uint           `gorm:"not null;index:idx_user_calendar_reminders_event_offset,priority:1" json:"event_id"`
	MinutesBefore int            `gorm:"not null;index:idx_user_calendar_reminders_event_offset,priority:2" json:"minutes_before"`
	Version       int64          `gorm:"not null;default:1" json:"version"`
	CreatedBy     string         `gorm:"size:24;not null;default:'user'" json:"created_by"`
	CreatedAt     time.Time      `json:"created_at"`
	UpdatedAt     time.Time      `json:"updated_at"`
	DeletedAt     gorm.DeletedAt `gorm:"index" json:"-"`
}

func (UserCalendarReminder) TableName() string { return "user_calendar_reminders" }

// UserCalendarActionDraft 将“模型提出”和“用户确认”分离，避免模型直接写入日历。
type UserCalendarActionDraft struct {
	ID                 uint       `gorm:"primaryKey" json:"id"`
	UserID             uint       `gorm:"not null;index;uniqueIndex:idx_user_calendar_action_drafts_user_key,priority:1" json:"-"`
	ActionType         string     `gorm:"size:64;not null;index" json:"action_type"`
	Status             string     `gorm:"size:24;not null;index" json:"status"`
	Title              string     `gorm:"size:160;not null" json:"title"`
	Description        string     `gorm:"type:text" json:"description"`
	StartAt            time.Time  `gorm:"not null" json:"start_at"`
	EndAt              time.Time  `gorm:"not null" json:"end_at"`
	AllDay             bool       `gorm:"not null;default:false" json:"all_day"`
	Location           string     `gorm:"size:200" json:"location"`
	Timezone           string     `gorm:"size:64;not null;default:'Asia/Shanghai'" json:"timezone"`
	PayloadHash        string     `gorm:"size:64;not null" json:"-"`
	IdempotencyKey     string     `gorm:"size:100;not null;uniqueIndex:idx_user_calendar_action_drafts_user_key,priority:2" json:"-"`
	TargetEventID      *uint      `gorm:"index" json:"target_event_id,omitempty"`
	TargetEventVersion int64      `gorm:"not null;default:0" json:"-"`
	ReminderMinutes    *int       `json:"reminder_minutes_before,omitempty"`
	CalendarEventID    *uint      `gorm:"index" json:"calendar_event_id,omitempty"`
	ExpiresAt          time.Time  `gorm:"not null;index" json:"expires_at"`
	ConfirmedAt        *time.Time `json:"confirmed_at,omitempty"`
	ExecutedAt         *time.Time `json:"executed_at,omitempty"`
	CancelledAt        *time.Time `json:"cancelled_at,omitempty"`
	FailureReason      string     `gorm:"size:200" json:"failure_reason,omitempty"`
	CreatedAt          time.Time  `json:"created_at"`
	UpdatedAt          time.Time  `json:"updated_at"`
}

func (UserCalendarActionDraft) TableName() string { return "user_calendar_action_drafts" }

type UserCalendarActionAudit struct {
	ID              uint      `gorm:"primaryKey" json:"id"`
	DraftID         uint      `gorm:"not null;index" json:"draft_id"`
	UserID          uint      `gorm:"not null;index" json:"user_id"`
	Action          string    `gorm:"size:32;not null;index" json:"action"`
	ClientRequestID string    `gorm:"size:100" json:"client_request_id,omitempty"`
	Result          string    `gorm:"size:100" json:"result"`
	CreatedAt       time.Time `gorm:"index" json:"created_at"`
}

func (UserCalendarActionAudit) TableName() string { return "user_calendar_action_audits" }
