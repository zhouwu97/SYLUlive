package models

import "gorm.io/gorm"

// MarkLegacyBundledConsents 降级旧捆绑确认，保留原始场景，避免多场景证据碰撞唯一键。
func MarkLegacyBundledConsents(db *gorm.DB) error {
	return db.Model(&UserLegalConsent{}).
		Where("document IN ? AND acknowledgement_type <> ?", []string{
			LegalDocumentCommunityRules,
			LegalDocumentMinorProtection,
			LegalDocumentContentComplaint,
			LegalDocumentSDKDisclosure,
		}, "rules_acceptance").
		Updates(map[string]interface{}{
			"acknowledgement_type": "legacy_bundled",
			"scope":                "legacy",
		}).Error
}
