package services

import (
	"errors"

	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// 新 AI 作者从独立区间分配，避免消耗普通注册账号的自增编号。
// 历史作者主键保留，帖子、评论和审计关联可继续使用。
const managedBotActorIDBase uint64 = 1_000_000_000_000
const managedBotActorIDLimit uint64 = 9_007_199_254_740_991

func createManagedBotActor(tx *gorm.DB, actor *models.User) error {
	// SQLite 的 rowid 分配始终参考表内最大值，仅用于本地夹具，保留其原分配方式。
	if tx.Dialector.Name() != "postgres" {
		return tx.Create(actor).Error
	}
	if err := tx.Exec("SELECT pg_advisory_xact_lock(hashtext(?))", "sylulive-managed-bot-actor").Error; err != nil {
		return err
	}
	var last uint64
	if err := tx.Model(&models.User{}).Select("COALESCE(MAX(id), ?)", managedBotActorIDBase).Where("id >= ?", managedBotActorIDBase).Scan(&last).Error; err != nil {
		return err
	}
	if last >= managedBotActorIDLimit {
		return errors.New("managed bot actor ID range exhausted")
	}
	actor.ID = uint(last + 1)
	return tx.Create(actor).Error
}
