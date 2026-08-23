package models

import "gorm.io/gorm"

// EnsurePushDeviceIndexes 建立远程推送绑定的数据库级不变量。
//
// RegistrationID 允许在历史 disabled 记录中重复，但同一时间只能由一个
// enabled 安装持有；这与 UpdatePushSettings 的转移语义一致，也能兜住并发请求。
func EnsurePushDeviceIndexes(db *gorm.DB) error {
	return db.Exec(`
CREATE UNIQUE INDEX IF NOT EXISTS uq_push_devices_active_registration_id
ON push_devices (registration_id)
WHERE enabled = TRUE AND registration_id <> ''`).Error
}
