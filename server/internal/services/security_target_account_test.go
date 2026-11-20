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

func TestSecurityTargetAccountPreservesUnregisteredLoginAndAggregation(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.SecurityEvent{}))
	service := NewSecurityEventService(db, "account-test-secret", nil)
	input := SecurityEventInput{EventType: "login_bruteforce", TargetType: "account", TargetValue: "unknown@example.invalid",
		TargetMasked: "un***@example.invalid", ClientIP: "203.0.113.8", Blocked: true}
	require.NoError(t, service.Record(input))
	var first models.SecurityEvent
	require.NoError(t, db.First(&first).Error)
	input.RequestID = "synthetic-request-id"
	require.NoError(t, service.Record(input))
	var event models.SecurityEvent
	require.NoError(t, db.First(&event).Error)
	require.Equal(t, 2, event.AttemptCount)
	require.Equal(t, 2, event.BlockedCount)
	require.NotEmpty(t, event.TargetAccountCiphertext)
	require.Equal(t, first.TargetAccountCiphertext, event.TargetAccountCiphertext)
	require.Equal(t, input.RequestID, event.RequestIDSample)
	account, status := service.TargetAccount(event)
	require.Equal(t, input.TargetValue, account)
	require.Equal(t, "available", status)
	encoded, err := json.Marshal(event)
	require.NoError(t, err)
	require.NotContains(t, string(encoded), input.TargetValue)
	require.NotContains(t, string(encoded), event.TargetAccountCiphertext)
	// 即使调用方复用聚合键，其他目标的密文也不能填进已有摘要对应的历史记录。
	historical := event
	historical.ID = 0
	historical.BucketKey = "historical-target"
	historical.TargetAccountCiphertext = ""
	require.NoError(t, db.Create(&historical).Error)
	input.AggregateKey = historical.BucketKey
	input.TargetValue = "different@example.invalid"
	require.NoError(t, service.Record(input))
	require.NoError(t, db.First(&historical, historical.ID).Error)
	require.Empty(t, historical.TargetAccountCiphertext)
	input.TargetValue = "unknown@example.invalid"
	require.NoError(t, service.Record(input))
	require.NoError(t, db.First(&historical, historical.ID).Error)
	account, status = service.TargetAccount(historical)
	require.Equal(t, input.TargetValue, account)
	require.Equal(t, "available", status)
}

func TestSecurityTargetAccountEncryptionBoundariesAndTampering(t *testing.T) {
	service := NewSecurityEventService(nil, "account-test-secret", nil)
	for _, target := range []string{"1234567890", "unknown@example.invalid", strings.Repeat("测", 320)} {
		input := SecurityEventInput{EventType: "login_bruteforce", TargetType: "account", TargetValue: target}
		ciphertext, err := service.encryptTargetAccount(input)
		require.NoError(t, err)
		require.NotEmpty(t, ciphertext)
		require.LessOrEqual(t, len(ciphertext), 2048)
		event := models.SecurityEvent{EventType: input.EventType, TargetType: input.TargetType, TargetHash: service.Hash(target), TargetAccountCiphertext: ciphertext}
		account, status := service.TargetAccount(event)
		require.Equal(t, target, account)
		require.Equal(t, "available", status)
		for _, mutate := range []func(*models.SecurityEvent){
			func(e *models.SecurityEvent) { e.TargetHash = service.Hash("another-target") },
			func(e *models.SecurityEvent) { e.TargetAccountCiphertext = "corrupt" },
		} {
			changed := event
			mutate(&changed)
			account, status = service.TargetAccount(changed)
			require.Empty(t, account)
			require.Equal(t, "unavailable", status)
		}
		account, status = NewSecurityEventService(nil, "rotated-key", nil).TargetAccount(event)
		require.Empty(t, account)
		require.Equal(t, "unavailable", status)
		var missing *SecurityEventService
		account, status = missing.TargetAccount(event)
		require.Empty(t, account)
		require.Equal(t, "unavailable", status)
	}
	for _, input := range []SecurityEventInput{
		{EventType: "login_failed", TargetType: "account", TargetValue: "private@example.invalid"},
		{EventType: "login_success", TargetType: "account", TargetValue: "private@example.invalid"},
		{EventType: "login_password_spray", TargetType: "route", TargetValue: "/api/login"},
		{EventType: "login_bruteforce", TargetType: "account", TargetValue: strings.Repeat("x", 321)},
		{EventType: "login_bruteforce", TargetType: "account", TargetValue: "\xff"},
	} {
		ciphertext, err := service.encryptTargetAccount(input)
		require.NoError(t, err)
		require.Empty(t, ciphertext)
	}
	ciphertext, err := service.encryptTargetAccount(SecurityEventInput{EventType: "email_target_flood", TargetType: "email", TargetValue: "target@example.invalid"})
	require.NoError(t, err)
	require.NotEmpty(t, ciphertext)
}

func TestSecurityTargetAccountMigrationPreservesHistoricalEvents(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.SecurityEvent{}))
	require.NoError(t, db.Migrator().DropColumn(&models.SecurityEvent{}, "TargetAccountCiphertext"))
	require.NoError(t, db.Exec("INSERT INTO security_events (bucket_key, event_type, severity, status, route, method, target_type, target_hash, target_masked, action, first_seen_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
		"legacy", "login_bruteforce", "medium", "active", "/api/login", "POST", "account", "historical-hash", "un***@example.invalid", "blocked", time.Now()).Error)
	require.NoError(t, db.AutoMigrate(&models.SecurityEvent{}))
	var event models.SecurityEvent
	require.NoError(t, db.First(&event).Error)
	require.Empty(t, event.TargetAccountCiphertext)
	account, status := NewSecurityEventService(db, "account-test-secret", nil).TargetAccount(event)
	require.Empty(t, account)
	require.Equal(t, "not_recorded", status)
}
