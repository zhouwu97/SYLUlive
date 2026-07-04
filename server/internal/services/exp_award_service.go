package services

import (
	"errors"
	"log"
	"time"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
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

// ExpAward 一条经验奖励结果，用于接口返回给前端展示提示。
type ExpAward struct {
	Scope       string `json:"scope"`             // "global" / "water_section"
	Exp         int    `json:"exp"`               // 本次发放的经验
	Action      string `json:"action"`            // post_daily / reply_daily
	LevelBefore int    `json:"level_before"`      // 发放前等级
	LevelAfter  int    `json:"level_after"`       // 发放后等级
	LevelUp     bool   `json:"level_up"`          // 是否升级
	// 仅当 scope=water_section
	SectionID         uint   `json:"section_id,omitempty"`
	SectionSlug       string `json:"section_slug,omitempty"`
	SectionTitle      string `json:"section_title,omitempty"`
	TitleBefore       string `json:"title_before,omitempty"`
	TitleAfter        string `json:"title_after,omitempty"`
	// 仅当 scope=global
	UserLevelTitleBefore string `json:"user_level_title_before,omitempty"`
	UserLevelTitleAfter  string `json:"user_level_title_after,omitempty"`
}

// AwardDailyGlobalExp 发放每日全局经验。
// 唯一约束冲突视为"今天已发"，返回 (false, nil)。
// 其它错误日志并返回，但调用方不应让主流程失败。
//
// 返回值：
//   awarded: 本次是否成功发放（true 表示今天首次发放到 global exp）
//   result:  ExpAward 详情（仅当 awarded=true 时有意义）
//   err:     非 ErrRecordNotFound 的错误
func AwardDailyGlobalExp(db *gorm.DB, userID uint, action string, exp int, refType string, refID uint) (bool, *ExpAward, error) {
	now := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.Local)

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
		if err := tx.Create(&expLog).Error; err != nil {
			// 唯一约束冲突 → 今天已发，不算错误
			if errors.Is(err, gorm.ErrDuplicatedKey) {
				return nil
			}
			// 旧版 SQLite/MySQL 没有专门 ErrDuplicatedKey 时退到错误本身
			// 通过尝试查询来确认今天是否已有记录
			var existing models.ExpLog
			lookupErr := tx.Where("user_id = ? AND action = ? AND date = ?", userID, action, today).First(&existing).Error
			if lookupErr == nil {
				return nil // 今天已发
			}
			return err
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
		return true, &ExpAward{
			Scope:       "global",
			Exp:         exp,
			Action:      action,
			LevelBefore: levelBefore,
			LevelAfter:  levelBefore,
		}, nil
	}
	levelAfter := CalculateUserLevel(afterUser.Exp)
	return true, &ExpAward{
		Scope:               "global",
		Exp:                 exp,
		Action:              action,
		LevelBefore:         levelBefore,
		LevelAfter:          levelAfter,
		LevelUp:             levelAfter > levelBefore,
		UserLevelTitleBefore: userLevelTitle(levelBefore),
		UserLevelTitleAfter:  userLevelTitle(levelAfter),
	}, nil
}

// AwardDailySectionExp 发放每日版块经验（仅适用于水帖版块）。
// 唯一约束冲突视为今天已发，返回 (false, nil)。
func AwardDailySectionExp(db *gorm.DB, userID uint, sectionID uint, sectionSlug string, sectionTitle string, action string, exp int, refType string, refID uint) (bool, *ExpAward, error) {
	now := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.Local)

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
		if err := tx.Create(&expLog).Error; err != nil {
			if errors.Is(err, gorm.ErrDuplicatedKey) {
				return nil
			}
			var existing models.WaterSectionExpLog
			lookupErr := tx.Where("user_id = ? AND section_id = ? AND action = ? AND date = ?", userID, sectionID, action, today).First(&existing).Error
			if lookupErr == nil {
				return nil
			}
			return err
		}
		// 更新或创建 stats
		var stat models.WaterSectionUserStat
		dbErr := tx.Where("user_id = ? AND section_id = ?", userID, sectionID).First(&stat).Error
		if dbErr == gorm.ErrRecordNotFound {
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
			if err := tx.Create(&stat).Error; err != nil {
				// 并发冲突退化为更新路径
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
	return true, &ExpAward{
		Scope:        "water_section",
		Exp:          exp,
		Action:       action,
		LevelBefore:  levelBefore,
		LevelAfter:   levelAfter,
		LevelUp:      levelAfter > levelBefore,
		SectionID:         sectionID,
		SectionSlug:       sectionSlug,
		SectionTitle:      sectionTitle,
		TitleBefore:       titleBefore,
		TitleAfter:        titleAfter,
	}, nil
}

// getSectionLevelInfo 读取用户在某版块内当前等级与称号（含默认称号）。
func getSectionLevelInfo(db *gorm.DB, userID uint, sectionID uint) (int, string) {
	var stat models.WaterSectionUserStat
	err := db.Where("user_id = ? AND section_id = ?", userID, sectionID).First(&stat).Error
	if err == gorm.ErrRecordNotFound {
		return 1, DefaultWaterSectionLevelTitle(1)
	}
	if err != nil {
		// 失败保守返回 Lv.1
		return 1, DefaultWaterSectionLevelTitle(1)
	}
	level := CalculateWaterSectionLevel(stat.Exp)
	title := getWaterSectionLevelTitle(db, sectionID, level)
	return level, title
}

// getWaterSectionLevelTitle 优先返回版主自定义称号，找不到则用默认称号。
func getWaterSectionLevelTitle(db *gorm.DB, sectionID uint, level int) string {
	var custom models.WaterSectionLevelTitle
	if err := db.Where("section_id = ? AND level = ?", sectionID, level).First(&custom).Error; err == nil && custom.Title != "" {
		return custom.Title
	}
	return DefaultWaterSectionLevelTitle(level)
}

// userLevelTitle 全站等级展示用称号（前端目前只关注 Lv.x 数字，
// 这里返回一个简短中文以便后端日志/接口可选使用，前端已有自己的 levelLabel）。
func userLevelTitle(level int) string {
	switch level {
	case 1:
		return "Lv.1"
	case 2:
		return "Lv.2"
	case 3:
		return "Lv.3"
	case 4:
		return "Lv.4"
	case 5:
		return "Lv.5"
	case 6:
		return "Lv.6"
	case 7:
		return "Lv.7"
	case 8:
		return "Lv.8"
	default:
		return ""
	}
}