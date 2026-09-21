package models

import (
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/datatypes"
	"gorm.io/gorm"
)

func TestCleanupCompetitionObservabilityDataUsesSeparateTTLs(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&CompetitionCandidateSignals{}, &CompetitionRankTrace{}))
	now := time.Date(2026, 9, 20, 12, 0, 0, 0, time.UTC)
	oldSignal := CompetitionCandidateSignals{UserID: 1, Kind: CompetitionSignalImpression, SessionKey: "s", EventID: 1, CreatedAt: now.Add(-91 * 24 * time.Hour)}
	newSignal := CompetitionCandidateSignals{UserID: 1, Kind: CompetitionSignalClick, SessionKey: "s", EventID: 2, CreatedAt: now.Add(-89 * 24 * time.Hour)}
	oldTrace := CompetitionRankTrace{UserID: 1, RunKey: "old", EventID: 1, Breakdown: datatypes.JSON(`{}`), CreatedAt: now.Add(-31 * 24 * time.Hour)}
	newTrace := CompetitionRankTrace{UserID: 1, RunKey: "new", EventID: 2, Breakdown: datatypes.JSON(`{}`), CreatedAt: now.Add(-29 * 24 * time.Hour)}
	require.NoError(t, db.Create(&[]CompetitionCandidateSignals{oldSignal, newSignal}).Error)
	require.NoError(t, db.Create(&[]CompetitionRankTrace{oldTrace, newTrace}).Error)

	signals, traces, err := CleanupCompetitionObservabilityData(db, now, 90*24*time.Hour, 30*24*time.Hour, 100)
	require.NoError(t, err)
	require.EqualValues(t, 1, signals)
	require.EqualValues(t, 1, traces)
	var signalCount, traceCount int64
	require.NoError(t, db.Model(&CompetitionCandidateSignals{}).Count(&signalCount).Error)
	require.NoError(t, db.Model(&CompetitionRankTrace{}).Count(&traceCount).Error)
	require.EqualValues(t, 1, signalCount)
	require.EqualValues(t, 1, traceCount)
}

func TestEnsureCompetitionSignalIndexesCleansHistoricalDuplicateImpressions(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&CompetitionCandidateSignals{}))
	duplicates := []CompetitionCandidateSignals{
		{UserID: 1, Kind: CompetitionSignalImpression, SessionKey: "session", EventID: 9},
		{UserID: 1, Kind: CompetitionSignalImpression, SessionKey: "session", EventID: 9},
		{UserID: 1, Kind: CompetitionSignalClick, SessionKey: "session", EventID: 9},
	}
	require.NoError(t, db.Create(&duplicates).Error)
	require.NoError(t, EnsureCompetitionSignalIndexes(db))
	var impressionCount int64
	require.NoError(t, db.Model(&CompetitionCandidateSignals{}).
		Where("kind = ?", CompetitionSignalImpression).Count(&impressionCount).Error)
	require.EqualValues(t, 1, impressionCount)
	duplicate := CompetitionCandidateSignals{UserID: 1, Kind: CompetitionSignalImpression, SessionKey: "session", EventID: 9}
	require.Error(t, db.Create(&duplicate).Error)
}
