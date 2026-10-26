package services

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

func TestSecuritySourceIPEncryptedAndBoundToFingerprint(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.SecurityEvent{}))
	service := NewSecurityEventService(db, "ip-test-secret", nil)
	input := SecurityEventInput{EventType: "login_bruteforce", ClientIP: "240e:abcd::1234", Route: "/api/login"}
	require.NoError(t, service.Record(input))
	require.NoError(t, service.Record(input))
	var event models.SecurityEvent
	require.NoError(t, db.First(&event).Error)
	require.Equal(t, 2, event.AttemptCount)
	require.NotEmpty(t, event.SourceIPCiphertext)
	require.NotContains(t, event.SourceIPCiphertext, input.ClientIP)
	ip, status := service.SourceIP(event)
	require.Equal(t, input.ClientIP, ip)
	require.Equal(t, "available", status)
	encoded, err := json.Marshal(event)
	require.NoError(t, err)
	require.NotContains(t, string(encoded), input.ClientIP)
	require.NotContains(t, string(encoded), event.SourceIPCiphertext)
	event.SourceIPHash = service.Hash("1.2.3.4")
	ip, status = service.SourceIP(event)
	require.Empty(t, ip)
	require.Equal(t, "unavailable", status)
}

func TestSecuritySourceIPSkipsAuditInvalidAndUntrusted(t *testing.T) {
	service := NewSecurityEventService(nil, "test-secret", nil)
	for _, c := range []struct {
		kind, ip, hash string
		valid          bool
	}{
		{"login_success", "1.2.3.4", "", true},
		{"login_failed", "1.2.3.4", "", true},
		{"login_bruteforce", "1.2.3.4", "", false},
		{"login_bruteforce", "not an ip", "", true},
		{"login_bruteforce", "fe80::1%eth0", "", true},
		{"login_bruteforce", "1.2.3.4", "forged-hash", true},
	} {
		hash := c.hash
		if hash == "" {
			hash = service.Hash(c.ip)
		}
		ciphertext, err := service.encryptSourceIP(SecurityEventInput{EventType: c.kind, ClientIP: c.ip}, hash, c.valid)
		require.NoError(t, err)
		require.Empty(t, ciphertext)
	}
	_, status := service.SourceIP(models.SecurityEvent{SourceAttributionValid: true, EventType: "login_bruteforce"})
	require.Equal(t, "not_recorded", status)
}

func TestSecuritySourceIPPreservedAcrossCallbacksAndKeyRotation(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.SecurityEvent{}))
	now := time.Date(2026, 10, 25, 1, 1, 0, 0, time.UTC)
	service := NewSecurityEventService(db, "old-key", func() time.Time { return now })
	input := SecurityEventInput{EventType: "verification_spray", ClientIP: "::ffff:1.2.3.4", Route: "/api/login"}
	require.NoError(t, service.Record(input))
	input.SourceHash = service.Hash(input.ClientIP)
	input.ClientIP = ""
	input.SkipAttempt = true
	require.NoError(t, service.Record(input))
	var event models.SecurityEvent
	require.NoError(t, db.First(&event).Error)
	ip, status := service.SourceIP(event)
	require.Equal(t, "1.2.3.4", ip)
	require.Equal(t, "available", status)
	rotated := NewSecurityEventService(db, "new-key", nil)
	ip, status = rotated.SourceIP(event)
	require.Empty(t, ip)
	require.Equal(t, "unavailable", status)
	event.SourceIPCiphertext = strings.Repeat("!", 20)
	ip, status = service.SourceIP(event)
	require.Empty(t, ip)
	require.Equal(t, "unavailable", status)
}

func TestSecuritySourceIPMigrationPreservesHistoricalEvents(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.SecurityEvent{}))
	event := models.SecurityEvent{BucketKey: "historical", EventType: "login_bruteforce", Severity: "high", Status: "active", SourceIPHash: "historical-fingerprint", SourceAttributionValid: true, AttemptCount: 20}
	require.NoError(t, db.Create(&event).Error)
	require.NoError(t, db.Migrator().DropColumn(&models.SecurityEvent{}, "source_ip_ciphertext"))
	require.NoError(t, db.AutoMigrate(&models.SecurityEvent{}))
	var restored models.SecurityEvent
	require.NoError(t, db.First(&restored, event.ID).Error)
	require.Equal(t, event.SourceIPHash, restored.SourceIPHash)
	require.Equal(t, 20, restored.AttemptCount)
	service := NewSecurityEventService(db, "new-key", nil)
	ip, status := service.SourceIP(restored)
	require.Empty(t, ip)
	require.Equal(t, "not_recorded", status)
}
