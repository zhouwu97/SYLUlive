package models

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func TestMarkLegacyBundledConsentsPreservesEvidenceAndIsRepeatable(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "consents.db")), &gorm.Config{})
	require.NoError(t, err)
	// Windows 必须先关闭连接，再由 TempDir 清理数据库文件。
	sqlDB, err := db.DB()
	require.NoError(t, err)
	t.Cleanup(func() { _ = sqlDB.Close() })
	require.NoError(t, db.AutoMigrate(&UserLegalConsent{}))
	now := time.Now().UTC().Truncate(time.Second)
	rows := []UserLegalConsent{
		{UserID: 1, Document: LegalDocumentSDKDisclosure, Version: "v1", Scene: "registration", AcceptedAt: now, AcknowledgementType: "separate_consent", RevokedAt: &now},
		{UserID: 1, Document: LegalDocumentSDKDisclosure, Version: "v1", Scene: "migration", AcceptedAt: now, AcknowledgementType: "legacy_bundled", Scope: "legacy"},
		{UserID: 1, Document: LegalDocumentCommunityRules, Version: "v1", Scene: "posting", AcceptedAt: now, AcknowledgementType: "rules_acceptance", Scope: "community"},
		{UserID: 1, Document: LegalDocumentPrivacyPolicy, Version: "v1", Scene: "registration", AcceptedAt: now, AcknowledgementType: "separate_consent", Scope: "account"},
	}
	require.NoError(t, db.Create(&rows).Error)
	for attempt := 0; attempt < 2; attempt++ {
		require.NoError(t, MarkLegacyBundledConsents(db))
		var got []UserLegalConsent
		require.NoError(t, db.Order("id").Find(&got).Error)
		require.Len(t, got, len(rows))
		for i, row := range got {
			require.Equal(t, rows[i].ID, row.ID)
			require.Equal(t, rows[i].Scene, row.Scene)
			require.True(t, rows[i].AcceptedAt.Equal(row.AcceptedAt))
			if i < 2 {
				require.Equal(t, "legacy_bundled", row.AcknowledgementType)
				require.Equal(t, "legacy", row.Scope)
			} else {
				require.Equal(t, rows[i].AcknowledgementType, row.AcknowledgementType)
				require.Equal(t, rows[i].Scope, row.Scope)
			}
		}
		require.NotNil(t, got[0].RevokedAt)
		require.True(t, now.Equal(*got[0].RevokedAt))
	}
}
