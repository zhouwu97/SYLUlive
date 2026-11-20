package models

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func TestLegalVersionChangeRequiresExplicitAcceptanceAndPreservesOldEvidence(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "legal-version.db")), &gorm.Config{})
	require.NoError(t, err)
	connection, err := db.DB()
	require.NoError(t, err)
	t.Cleanup(func() { _ = connection.Close() })
	require.NoError(t, db.AutoMigrate(&UserLegalConsent{}))
	user := User{ID: 91}
	for _, document := range RequiredLegalDocuments(false) {
		require.NoError(t, db.Create(&UserLegalConsent{UserID: user.ID, Document: document, Version: "2026-09-22-r3", AcceptedAt: time.Now()}).Error)
	}
	state, err := LegalConsentStateForUser(db, user)
	require.NoError(t, err)
	require.Equal(t, LegalConsentStateRequired, state)
	for _, document := range RequiredLegalDocuments(false) {
		require.NoError(t, db.Create(&UserLegalConsent{UserID: user.ID, Document: document, Version: LegalDocumentVersion, AcceptedAt: time.Now()}).Error)
	}
	state, err = LegalConsentStateForUser(db, user)
	require.NoError(t, err)
	require.Equal(t, LegalConsentStateActive, state)
	var oldCount int64
	require.NoError(t, db.Model(&UserLegalConsent{}).Where("user_id = ? AND version = ?", user.ID, "2026-09-22-r3").Count(&oldCount).Error)
	require.EqualValues(t, 2, oldCount)
	user.LegalConsentRevokedAt = new(time.Time)
	state, err = LegalConsentStateForUser(db, user)
	require.NoError(t, err)
	require.Equal(t, LegalConsentStateRevoked, state)
}
