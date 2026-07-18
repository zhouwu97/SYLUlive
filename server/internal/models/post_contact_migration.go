package models

import (
	"regexp"
	"strings"

	"gorm.io/gorm"
)

var (
	legacyMarketContactPrefix = regexp.MustCompile(`(?i)^\s*(微信号?|QQ号?|电话|手机号)\s*[：:]\s*(.*?)\s*$`)
	legacyMarketContactSuffix = regexp.MustCompile(`(?i)^\s*(.*?)\s*[（(]\s*(微信号?|QQ号?|电话|手机号)\s*[）)]\s*$`)
)

// BackfillLegacyMarketContacts 将可明确识别的历史联系方式拆成类型和账号。
// 无法判断的值保留原文并标记为 other；函数只处理空类型记录，可重复执行。
func BackfillLegacyMarketContacts(db *gorm.DB) error {
	var posts []Post
	if err := db.Select("id", "contact").
		Where("board_id = ? AND contact <> ? AND (contact_type IS NULL OR contact_type = ?)", BoardMarket, "", "").
		Find(&posts).Error; err != nil {
		return err
	}

	return db.Transaction(func(tx *gorm.DB) error {
		for _, post := range posts {
			contactType, contact := parseLegacyMarketContact(post.Contact)
			if err := tx.Model(&Post{}).Where("id = ? AND (contact_type IS NULL OR contact_type = ?)", post.ID, "").
				Updates(map[string]interface{}{
					"contact_type": contactType,
					"contact":      contact,
				}).Error; err != nil {
				return err
			}
		}
		return nil
	})
}

func parseLegacyMarketContact(raw string) (MarketContactType, string) {
	trimmed := strings.TrimSpace(raw)
	if matches := legacyMarketContactPrefix.FindStringSubmatch(trimmed); len(matches) == 3 {
		if contact := strings.TrimSpace(matches[2]); contact != "" {
			return legacyMarketContactType(matches[1]), contact
		}
	}
	if matches := legacyMarketContactSuffix.FindStringSubmatch(trimmed); len(matches) == 3 {
		if contact := strings.TrimSpace(matches[1]); contact != "" {
			return legacyMarketContactType(matches[2]), contact
		}
	}
	return MarketContactTypeOther, trimmed
}

func legacyMarketContactType(label string) MarketContactType {
	switch strings.ToLower(strings.TrimSpace(label)) {
	case "微信", "微信号":
		return MarketContactTypeWeChat
	case "qq", "qq号":
		return MarketContactTypeQQ
	default:
		return MarketContactTypePhone
	}
}
