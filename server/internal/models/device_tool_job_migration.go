package models

import (
	"errors"

	"gorm.io/gorm"
)

// EnsureDeviceToolJobIndexes 让同一等待周期内的设备任务保持幂等，
// 同时允许外层 Tool Call 在恢复后为新的缺失数据集创建下一轮任务。
func EnsureDeviceToolJobIndexes(db *gorm.DB) error {
	if db == nil {
		return errors.New("database is nil")
	}
	if err := db.Exec("DROP INDEX IF EXISTS idx_device_tool_jobs_run_call").Error; err != nil {
		return err
	}
	return db.Exec(`
		CREATE UNIQUE INDEX IF NOT EXISTS idx_device_tool_jobs_run_call_active
		ON device_tool_jobs (run_id, tool_call_id)
		WHERE status IN ('pending', 'pushed', 'claimed', 'waiting_user', 'running')
	`).Error
}
