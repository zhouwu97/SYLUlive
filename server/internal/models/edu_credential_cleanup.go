package models

import "time"

// EduCredentialCleanupJob 记录已撤销授权账号的教务服务凭证清理任务。
// 本地撤销事务提交后由后台重试，避免远端服务临时不可用阻断用户行使撤销权。
type EduCredentialCleanupJob struct {
	ID                 uint       `gorm:"primaryKey" json:"id"`
	UserID             uint       `gorm:"not null;index;uniqueIndex:ux_edu_cleanup_pending_generation,where:completed_at IS NULL" json:"-"`
	ExpectedGeneration uint       `gorm:"not null;default:0;index;uniqueIndex:ux_edu_cleanup_pending_generation,where:completed_at IS NULL" json:"-"`
	RevokedAt          *time.Time `json:"-"`
	DeleteIdentity     bool       `gorm:"not null;default:false" json:"-"`
	Attempts           int        `gorm:"not null;default:0" json:"attempts"`
	NextAttemptAt      time.Time  `gorm:"not null;index" json:"next_attempt_at"`
	CompletedAt        *time.Time `gorm:"index" json:"completed_at,omitempty"`
	LockedAt           *time.Time `gorm:"index" json:"-"`
	LockToken          string     `gorm:"size:36;index" json:"-"`
	LastError          string     `gorm:"size:1000" json:"last_error,omitempty"`
	CreatedAt          time.Time  `gorm:"index" json:"created_at"`
	UpdatedAt          time.Time  `json:"updated_at"`
}
