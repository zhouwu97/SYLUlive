package models

import (
	"time"

	"gorm.io/datatypes"
)

const (
	DeviceToolJobPending     = "pending"
	DeviceToolJobPushed      = "pushed"
	DeviceToolJobClaimed     = "claimed"
	DeviceToolJobWaitingUser = "waiting_user"
	DeviceToolJobRunning     = "running"
	DeviceToolJobCompleted   = "completed"
	DeviceToolJobFailed      = "failed"
	DeviceToolJobExpired     = "expired"
	DeviceToolJobCancelled   = "cancelled"
)

const (
	DeviceJobStageCheckingFreshness = "checking_freshness"
	DeviceJobStageRequestReceived   = "request_received"
	DeviceJobStageRefreshStarted    = "refresh_started"
	DeviceJobStageRefreshCompleted  = "refresh_completed"
	DeviceJobStageRefreshFailed     = "refresh_failed"
	DeviceJobStageReadingResult     = "reading_result"
)

// DeviceToolJob 保存一次临时设备读取请求。结果只用于关联 AI Run，不能当作长期个人快照。
type DeviceToolJob struct {
	ID                string         `gorm:"type:varchar(36);primaryKey" json:"id"`
	UserID            uint           `gorm:"not null;index:idx_device_jobs_user_status,priority:1" json:"-"`
	RunID             string         `gorm:"type:varchar(36);not null;index" json:"run_id"`
	ToolCallID        string         `gorm:"type:varchar(100);not null;index" json:"tool_call_id"`
	InstallationID    string         `gorm:"size:128;not null;index" json:"installation_id"`
	ToolName          string         `gorm:"size:100;not null;index" json:"tool_name"`
	ArgumentsJSON     datatypes.JSON `gorm:"type:jsonb;not null" json:"arguments"`
	RequiredDataTypes datatypes.JSON `gorm:"type:jsonb;not null" json:"required_data_types"`
	Status            string         `gorm:"size:24;not null;index:idx_device_jobs_user_status,priority:2" json:"status"`
	ProgressStage     string         `gorm:"size:32;not null;default:''" json:"progress_stage,omitempty"`
	StateVersion      int64          `gorm:"not null;default:0" json:"state_version"`
	ExpiresAt         time.Time      `gorm:"not null;index" json:"expires_at"`
	ClaimedAt         *time.Time     `json:"claimed_at,omitempty"`
	CompletedAt       *time.Time     `json:"completed_at,omitempty"`
	ResultJSON        datatypes.JSON `gorm:"type:jsonb" json:"result,omitempty"`
	ResultHash        string         `gorm:"size:64;not null;default:''" json:"-"`
	ErrorCode         string         `gorm:"size:64;not null;default:''" json:"error_code,omitempty"`
	CreatedAt         time.Time      `json:"created_at"`
	UpdatedAt         time.Time      `json:"updated_at"`
}

func (DeviceToolJob) TableName() string { return "device_tool_jobs" }
