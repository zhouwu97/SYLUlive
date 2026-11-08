package services

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
)

func TestIntegrationBotRuntimeLeasePublicationRevisionAndExpiry(t *testing.T) {
	db, s, binding, source := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
	ctx := context.Background()
	bot, err := s.ManageBot(ctx, 1, "合成机器人", true)
	require.NoError(t, err)
	grantBotParticipation(t, db, bot)
	binding.Scopes += " " + IntegrationAutoReplyScope
	require.NoError(t, db.Save(&binding).Error)
	now := time.Now()
	s.Auth.Now = func() time.Time { return now }
	report := BotRuntimeHeartbeat{SessionID: uuid.NewString(), Sequence: 1, Revision: bot.Revision, State: "loading", NextRunInSeconds: 1800}
	require.NoError(t, s.RecordBotRuntime(ctx, binding, report))
	status, err := s.BotRuntimeStatus(ctx, 1)
	require.NoError(t, err)
	require.Equal(t, "loading", status.State)
	require.Nil(t, status.LastAction)
	other := report
	other.SessionID = uuid.NewString()
	require.EqualError(t, s.RecordBotRuntime(ctx, binding, other), "bot_runtime_busy")
	require.EqualError(t, s.RecordBotRuntime(ctx, binding, report), "stale_bot_runtime")
	p := integrationReplyProposal(source)
	p.RuntimeSessionID, p.BotRevision = report.SessionID, bot.Revision
	original := p
	action, err := s.AutoReply(ctx, binding, p)
	require.NoError(t, err)
	require.Equal(t, "published", action.State)
	report.Sequence++
	report.State, report.RoundID, report.ReadCount = "completed", uuid.NewString(), 1
	require.NoError(t, s.RecordBotRuntime(ctx, binding, report))
	status, err = s.BotRuntimeStatus(ctx, 1)
	require.NoError(t, err)
	require.Equal(t, action.ReplyID, status.LastAction.ReplyID)
	require.WithinDuration(t, now, *status.LastReadAt, time.Second)
	readAt := *status.LastReadAt
	now = now.Add(time.Minute)
	report.Sequence++
	require.NoError(t, s.RecordBotRuntime(ctx, binding, report))
	status, err = s.BotRuntimeStatus(ctx, 1)
	require.NoError(t, err)
	require.Equal(t, readAt, *status.LastReadAt, "heartbeats cannot pretend a new browse happened")

	bot, err = s.UpdateManagedBot(ctx, 1, ManagedBotUpdate{Enabled: false})
	require.NoError(t, err)
	require.EqualError(t, s.RecordBotRuntime(ctx, binding, report), "bot_policy_changed")
	status, err = s.BotRuntimeStatus(ctx, 1)
	require.NoError(t, err)
	require.Equal(t, "paused", status.State)
	bot, err = s.ManageBot(ctx, 1, "", true)
	require.NoError(t, err)
	report.Revision, report.State, report.Sequence = bot.Revision, "loading", report.Sequence+1
	require.NoError(t, s.RecordBotRuntime(ctx, binding, report))
	now = now.Add(BotRuntimeLease + time.Second)
	status, err = s.BotRuntimeStatus(ctx, 1)
	require.NoError(t, err)
	require.Equal(t, "offline", status.State)
	other.Revision = bot.Revision
	require.NoError(t, s.RecordBotRuntime(ctx, binding, other))
	p.OperationID = uuid.NewString()
	p.BotRevision = bot.Revision
	_, err = s.AutoReply(ctx, binding, p)
	require.EqualError(t, err, "bot_runtime_required", "an expired worker cannot publish after takeover")
	repeated, err := s.AutoReply(ctx, binding, original)
	require.NoError(t, err)
	require.Equal(t, action.ReplyID, repeated.ReplyID, "the same operation may recover its committed receipt without publishing again")
	require.NoError(t, s.Auth.Revoke(ctx, 1, binding.ID))
	other.Sequence++
	require.Error(t, s.RecordBotRuntime(ctx, binding, other))
	status, err = s.BotRuntimeStatus(ctx, 1)
	require.NoError(t, err)
	require.Equal(t, "scope_required", status.State)
}

func TestIntegrationBotRuntimeTwoOwnersAndConcurrentLease(t *testing.T) {
	db, s, first, source := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
	ctx := context.Background()
	botA, err := s.ManageBot(ctx, 1, "A", true)
	require.NoError(t, err)
	integrationTestUser(t, db, 100)
	require.NoError(t, db.Create(&models.UserLegalConsent{UserID: 100, Document: models.LegalDocumentCommunityRules, AcknowledgementType: "rules_acceptance", Version: models.LegalDocumentVersion, AcceptedAt: time.Now()}).Error)
	second, _ := integrationAuthorize(t, s.Auth, 100, uuid.NewString())
	botB, err := s.ManageBot(ctx, 100, "B", true)
	require.NoError(t, err)
	reportA := BotRuntimeHeartbeat{SessionID: uuid.NewString(), Sequence: 1, Revision: botA.Revision, State: "loading"}
	reportB := BotRuntimeHeartbeat{SessionID: uuid.NewString(), Sequence: 1, Revision: botB.Revision, State: "loading"}
	require.NoError(t, s.RecordBotRuntime(ctx, first, reportA))
	require.NoError(t, s.RecordBotRuntime(ctx, second, reportB))
	grantBotParticipation(t, db, botA)
	first.Scopes += " " + IntegrationAutoReplyScope
	require.NoError(t, db.Save(&first).Error)
	p := integrationReplyProposal(source)
	p.RuntimeSessionID, p.BotRevision = reportA.SessionID, botA.Revision
	_, err = s.AutoReply(ctx, first, p)
	require.NoError(t, err)
	_, err = s.UpdateManagedBot(ctx, 1, ManagedBotUpdate{Enabled: false})
	require.NoError(t, err)
	stateA, err := s.BotRuntimeStatus(ctx, 1)
	require.NoError(t, err)
	stateB, err := s.BotRuntimeStatus(ctx, 100)
	require.NoError(t, err)
	require.Equal(t, "paused", stateA.State)
	require.Equal(t, "loading", stateB.State)
	require.Nil(t, stateB.LastAction, "another owner's successful publication must never appear here")

	now := time.Now().Add(BotRuntimeLease + time.Second)
	s.Auth.Now = func() time.Time { return now }
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r := reportB
			r.SessionID = uuid.NewString()
			results <- s.RecordBotRuntime(ctx, second, r)
		}()
	}
	wg.Wait()
	close(results)
	accepted := 0
	for err := range results {
		if err == nil {
			accepted++
		} else {
			require.EqualError(t, err, "bot_runtime_busy")
		}
	}
	require.Equal(t, 1, accepted)
}

func TestIntegrationBotRuntimeRejectsArbitraryStatusAndMissingReadScope(t *testing.T) {
	db, s, binding, _ := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
	bot, err := s.ManageBot(context.Background(), 1, "合成机器人", true)
	require.NoError(t, err)
	r := BotRuntimeHeartbeat{SessionID: uuid.NewString(), Sequence: 1, Revision: bot.Revision, State: "published"}
	require.EqualError(t, s.RecordBotRuntime(context.Background(), binding, r), "invalid_bot_runtime")
	r.State, r.ErrorCode = "error", "private model output"
	require.EqualError(t, s.RecordBotRuntime(context.Background(), binding, r), "invalid_bot_runtime")
	r.State, r.ErrorCode = "idle", ""
	binding.Scopes = "community:read"
	require.NoError(t, db.Save(&binding).Error)
	require.NoError(t, s.RecordBotRuntime(context.Background(), binding, r), "read-only bots need no proposal/write scope to report their own activity")
	binding.Scopes = "profile:read_minimal"
	require.NoError(t, db.Save(&binding).Error)
	require.EqualError(t, s.RecordBotRuntime(context.Background(), binding, r), "insufficient_scope")
}

func TestIntegrationBotRuntimeMigrationPreservesLegacyBotAndCurrentLease(t *testing.T) {
	db, s, binding, _ := integrationActionFixture(t)
	type legacyBot struct {
		OwnerID    uint   `gorm:"primaryKey"`
		UserID     uint   `gorm:"not null;uniqueIndex"`
		Enabled    bool   `gorm:"not null;default:false"`
		PolicyJSON string `gorm:"type:text;not null;default:''"`
		CreatedAt  time.Time
	}
	require.NoError(t, db.Table("managed_bots").AutoMigrate(&legacyBot{}))
	require.NoError(t, db.Table("managed_bots").Create(&legacyBot{OwnerID: 1, UserID: 99, Enabled: true, CreatedAt: time.Now()}).Error)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
	var migrated models.ManagedBot
	require.NoError(t, db.First(&migrated, "owner_id = ?", 1).Error)
	require.EqualValues(t, 99, migrated.UserID)
	require.True(t, migrated.Enabled)
	require.EqualValues(t, 1, migrated.Revision)
	require.Empty(t, migrated.RuntimeJSON)
	require.False(t, ManagedBotPolicy(migrated).ReplyEnabled)
	require.False(t, ManagedBotPolicy(migrated).PostEnabled)
	require.NoError(t, s.RecordBotRuntime(context.Background(), binding, BotRuntimeHeartbeat{SessionID: uuid.NewString(), Sequence: 1, Revision: 1, State: "idle"}))
	require.NoError(t, db.First(&migrated, "owner_id = ?", 1).Error)
	record := migrated.RuntimeJSON
	require.NotEmpty(t, record)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
	require.NoError(t, db.First(&migrated, "owner_id = ?", 1).Error)
	require.Equal(t, record, migrated.RuntimeJSON)
}
