package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
)

func TestPersonalSnapshotErkeSurvivesJSONBObjectKeyNormalization(t *testing.T) {
	db, service := newPersonalSnapshotTestService(t, time.Now())
	_, err := service.StoreErke(context.Background(), 1, validErkeSnapshotUpload(time.Now().Add(-time.Minute)))
	require.NoError(t, err)
	var row models.PersonalUploadedSnapshot
	require.NoError(t, db.First(&row).Error)
	canonical, err := canonicalAcademicPayload(row.PayloadJSON)
	require.NoError(t, err)
	require.NoError(t, db.Model(&row).Update("payload_json", string(canonical)).Error)
	lookup, err := service.LookupErke(context.Background(), 1)
	require.NoError(t, err)
	require.True(t, lookup.Found)
}

func TestPersonalSnapshotErkeReadsLegacyHashButRejectsTampering(t *testing.T) {
	db, service := newPersonalSnapshotTestService(t, time.Now())
	upload := validErkeSnapshotUpload(time.Now().Add(-time.Minute))
	payload, _, err := normalizeErkeSnapshotUpload(upload)
	require.NoError(t, err)
	legacy := sha256.Sum256(payload)
	_, err = service.StoreErke(context.Background(), 1, upload)
	require.NoError(t, err)
	var row models.PersonalUploadedSnapshot
	require.NoError(t, db.First(&row).Error)
	canonical, err := canonicalAcademicPayload(row.PayloadJSON)
	require.NoError(t, err)
	require.NoError(t, db.Model(&row).Updates(map[string]interface{}{"payload_json": string(canonical), "payload_hash": hex.EncodeToString(legacy[:])}).Error)
	_, err = service.LookupErke(context.Background(), 1)
	require.NoError(t, err)
	require.NoError(t, db.Model(&row).Update("payload_json", `{"graduation":{"earned_total":999},"yearly":{},"recent_activities":[]}`).Error)
	_, err = service.LookupErke(context.Background(), 1)
	require.Error(t, err)
}
