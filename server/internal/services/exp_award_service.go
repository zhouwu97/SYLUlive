package services

import (
	"errors"
	"log"
	"time"

	"shenliyuan/internal/academiccalendar"
	"shenliyuan/internal/models"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// 全局经验发放量
const (
	GlobalExpPostDaily  = 10 // 每日首发帖子全站经验
	GlobalExpReplyDaily = 3  // 每日首评全站经验
)

// 全局每日经验发放 action 名
const (
	GlobalActionPostDaily  = "post_daily"
	GlobalActionReplyDaily = "reply_daily"
)

// AwardDailyGlobalExp 发放每日全局经验。
// 唯一约束冲突视为"今天已发"，返回 (false, nil)。
// 其它错误日志并返回，但调用方不应让主流程失败。
//
// 返回值：
//
//	awarded: 本次是否成功发放（true 表示今天首次发放到 global exp）
//	result:  ExpAward 详情（仅当 awarded=true 时有意义）
//	err:     非 ErrRecordNotFound 的错误
func AwardDailyGlobalExp(db *gorm.DB, userID uint, action string, exp int, refType string, refID uint) (bool, *models.ExpAward, error) {
	now := time.Now()
	// 每日唯一键必须按上海自然日截断；时区不可用时宁可不发，也不按 UTC 错发。
	today, err := academiccalendar.DayStart(now)
	if err != nil {
		return false, nil, err
	}

	// 先读取当前用户经验，用于等级前后比对
	var beforeUser models.User
	if err := db.Select("exp").First(&beforeUser, userID).Error; err != nil {
		return false, nil, err
	}
	levelBefore := CalculateUserLevel(beforeUser.Exp)

	awarded := false
	txErr := db.Transaction(func(tx *gorm.DB) error {
		expLog := models.ExpLog{
			UserID:    userID,
			Action:    action,
			Date:      today,
			ExpEarned: exp,
		}
		result := tx.Clauses(clause.OnConflict{
			Columns:   []clause.Column{{Name: "user_id"}, {Name: "action"}, {Name: "date"}},
			DoNothing: true,
		}).Create(&expLog)
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected == 0 {
			return nil // 今天已发，保持事务可继续提交
		}
		if err := tx.Model(&models.User{}).Where("id = ?", userID).UpdateColumn("exp", gorm.Expr("exp + ?", exp)).Error; err != nil {
			return err
		}
		awarded = true
		return nil
	})
	if txErr != nil {
		log.Printf("[EXP_AWARD] global award failed user=%d action=%s exp=%d err=%v", userID, action, exp, txErr)
		// 发放失败不阻断主流程，但返回错误让调用方决定是否记日志
		return false, nil, txErr
	}
	if !awarded {
		return false, nil, nil
	}

	// 重新读出最新经验，算等级
	var afterUser models.User
	if err := db.Select("exp").First(&afterUser, userID).Error; err != nil {
		// 失败则不报等级信息
		return true, &models.ExpAward{
			Scope:       "global",
			Exp:         exp,
			Action:      action,
			LevelBefore: levelBefore,
			LevelAfter:  levelBefore,
		}, nil
	}
	levelAfter := CalculateUserLevel(afterUser.Exp)
	return true, &models.ExpAward{
		Scope:       "global",
		Exp:         exp,
		Action:      action,
		LevelBefore: levelBefore,
		LevelAfter:  levelAfter,
		LevelUp:     levelAfter > levelBefore,
	}, nil
}

// AwardDailySectionExp 发放每日版块经验（仅适用于水帖版块）。
// 唯一约束冲突视为今天已发，返回 (false, nil)。
func AwardDailySectionExp(db *gorm.DB, userID uint, sectionID uint, sectionSlug string, sectionTitle string, action string, exp int, refType string, refID uint) (bool, *models.ExpAward, error) {
	now := time.Now()
	// 与 AwardDailyGlobalExp 一致：按上海自然日截断，时区不可用时 fail-closed。
	today, err := academiccalendar.DayStart(now)
	if err != nil {
		return false, nil, err
	}

	// 读取发放前等级（用 stats 表，不存在则视为 Lv.1）
	levelBefore, titleBefore := getSectionLevelInfo(db, userID, sectionID)

	awarded := false
	txErr := db.Transaction(func(tx *gorm.DB) error {
		expLog := models.WaterSectionExpLog{
			UserID:    userID,
			SectionID: sectionID,
			Action:    action,
			Date:      today,
			ExpEarned: exp,
			RefType:   refType,
			RefID:     refID,
		}
		result := tx.Clauses(clause.OnConflict{
			Columns:   []clause.Column{{Name: "user_id"}, {Name: "section_id"}, {Name: "action"}, {Name: "date"}},
			DoNothing: true,
		}).Create(&expLog)
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected == 0 {
			return nil // 今天已发，保持事务可继续提交
		}
		// 更新或创建 stats
		var stat models.WaterSectionUserStat
		dbErr := tx.Where("user_id = ? AND section_id = ?", userID, sectionID).First(&stat).Error
		if errors.Is(dbErr, gorm.ErrRecordNotFound) {
			stat = models.WaterSectionUserStat{
				UserID:       userID,
				SectionID:    sectionID,
				Exp:          exp,
				LastActiveAt: now,
			}
			switch action {
			case GlobalActionPostDaily:
				stat.PostCount = 1
			case GlobalActionReplyDaily:
				stat.ReplyCount = 1
			}
			createResult := tx.Clauses(clause.OnConflict{
				Columns:   []clause.Column{{Name: "user_id"}, {Name: "section_id"}},
				DoNothing: true,
			}).Create(&stat)
			if createResult.Error != nil {
				return createResult.Error
			}
			if createResult.RowsAffected == 0 {
				// 并发创建已存在时，继续更新同一行，避免唯一键错误中止事务。
				if err := tx.Where("user_id = ? AND section_id = ?", userID, sectionID).First(&stat).Error; err != nil {
					return err
				}
				if err := tx.Model(&stat).Updates(map[string]interface{}{
					"exp":            gorm.Expr("exp + ?", exp),
					"last_active_at": now,
					"post_count":     gorm.Expr("CASE WHEN ? = 'post_daily' THEN post_count + 1 ELSE post_count END", action),
					"reply_count":    gorm.Expr("CASE WHEN ? = 'reply_daily' THEN reply_count + 1 ELSE reply_count END", action),
				}).Error; err != nil {
					return err
				}
			}
		} else if dbErr == nil {
			updates := map[string]interface{}{
				"exp":            gorm.Expr("exp + ?", exp),
				"last_active_at": now,
			}
			if action == GlobalActionPostDaily {
				updates["post_count"] = gorm.Expr("post_count + 1")
			} else if action == GlobalActionReplyDaily {
				updates["reply_count"] = gorm.Expr("reply_count + 1")
			}
			if err := tx.Model(&stat).Updates(updates).Error; err != nil {
				return err
			}
		} else {
			return dbErr
		}
		awarded = true
		return nil
	})
	if txErr != nil {
		log.Printf("[EXP_AWARD] section award failed user=%d section=%d action=%s exp=%d err=%v", userID, sectionID, action, exp, txErr)
		return false, nil, txErr
	}
	if !awarded {
		return false, nil, nil
	}

	levelAfter, titleAfter := getSectionLevelInfo(db, userID, sectionID)
	return true, &models.ExpAward{
		Scope:        "water_section",
		Exp:          exp,
		Action:       action,
		LevelBefore:  levelBefore,
		LevelAfter:   levelAfter,
		LevelUp:      levelAfter > levelBefore,
		SectionID:    sectionID,
		SectionSlug:  sectionSlug,
		SectionTitle: sectionTitle,
		TitleBefore:  titleBefore,
		TitleAfter:   titleAfter,
	}, nil
}

// getSectionLevelInfo 读取用户在某版块内当前等级与称号（含默认称号）。
func getSectionLevelInfo(db *gorm.DB, userID uint, sectionID uint) (int, string) {
	var stat models.WaterSectionUserStat
	err := db.Where("user_id = ? AND section_id = ?", userID, sectionID).First(&stat).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return 1, DefaultWaterSectionLevelTitle(1)
	}
	if err != nil {
		// 失败保守返回 Lv.1
		return 1, DefaultWaterSectionLevelTitle(1)
	}
	level := CalculateWaterSectionLevel(stat.Exp)
	title := GetWaterSectionLevelTitle(db, sectionID, level)
	return level, title
}

// GetWaterSectionLevelTitle 优先返回版主自定义称号，找不到则用默认称号。
func GetWaterSectionLevelTitle(db *gorm.DB, sectionID uint, level int) string {
	var custom models.WaterSectionLevelTitle
	if err := db.Where("section_id = ? AND level = ?", sectionID, level).First(&custom).Error; err == nil && custom.Title != "" {
		return custom.Title
	}
	return DefaultWaterSectionLevelTitle(level)
}

// userLevelTitle 已不再使用；保留位给后续需要全站等级展示文案的扩展。
