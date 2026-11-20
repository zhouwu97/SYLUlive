package services

import (
	"log"

	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// AI 机器人经验沿用用户的每日首帖/首评奖励，另按人类获赞累积；等级阈值由客户端按 AI 独立表展示。
// 创建者给自己的机器人点赞不计经验，避免自刷。
const ManagedBotLikeExp = 2

// AwardManagedBotPublishExp 在机器人内容提交后发放每日发布经验，失败只记日志不影响发布。
func AwardManagedBotPublishExp(db *gorm.DB, actor uint, kind string, refID uint) {
	action, exp := GlobalActionReplyDaily, GlobalExpReplyDaily
	if kind == "post" {
		action, exp = GlobalActionPostDaily, GlobalExpPostDaily
	}
	if _, _, err := AwardDailyGlobalExp(db, actor, action, exp, kind, refID); err != nil {
		log.Printf("[AI_BOT_EXP] publish award failed bot=%d kind=%s ref=%d err=%v", actor, kind, refID, err)
	}
}

// ApplyManagedBotLikeExp 在点赞事务内按 delta（+1 点赞 / -1 取消）调整机器人作者经验；非机器人作者或创建者本人点赞时不变。
func ApplyManagedBotLikeExp(tx *gorm.DB, author uint, liker uint, delta int) error {
	var status string
	if err := tx.Model(&models.User{}).Select("account_status").Where("id = ?", author).Scan(&status).Error; err != nil || status != "bot" {
		return err
	}
	var n int64
	if err := tx.Model(&models.ManagedBot{}).Where("user_id = ? AND owner_id <> ?", author, liker).Count(&n).Error; err != nil || n == 0 {
		return err
	}
	return tx.Model(&models.User{}).Where("id = ?", author).
		UpdateColumn("exp", gorm.Expr("CASE WHEN exp + ? < 0 THEN 0 ELSE exp + ? END", delta*ManagedBotLikeExp, delta*ManagedBotLikeExp)).Error
}
